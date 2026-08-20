// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOEngineCore
  import AIOSupport
  import Atomics
  import AVFoundation
  import Foundation
  import os
  import Tools

  private let interruptionPolicyLog = SystemLog.make()

  /// Shared recording and playback recovery policy for normalized audio-system
  /// events. Platform adapters only capture values and construct
  /// `AudioSystemEvent`.
  @MainActor
  struct InterruptionPolicy {
    let owner: AIOEngine

    func handle(_ event: AudioSystemEvent) async {
      switch event {
      case .routeChanged(let change):
        await handleRouteChange(change)
      case .interruptionBegan:
        await handleInterruptionBegan()
      case .interruptionEnded(let shouldResume):
        await handleInterruptionEnded(shouldResume: shouldResume)
      case .mediaServicesLost:
        await handleMediaServicesLost()
      case .mediaServicesReset:
        await handleMediaServicesReset()
      case .sessionActivated:
        // Applied-state reconciliation is the environment manager's job. Here
        // it is diagnostics only: activation is never a recovery trigger.
        interruptionPolicyLog.info("Audio session became active")
      case .sessionDeactivated(let deactivation):
        await handleSessionDeactivated(deactivation)
      case .resumptionRecommended(let shouldResume):
        await handleResumptionRecommended(shouldResume)
      }
    }

    /// iOS 27 surfaces one interruption through *both*
    /// `interruptionBegan`/`Ended` and `didBecomeInactive`/`didBecomeActive`.
    /// The dedup rule: interruption events are the recovery trigger, and a
    /// session-state event only stages recovery when nothing is staged yet.
    private func handleSessionDeactivated(
      _ deactivation: AudioSessionDeactivation,
    ) async {
      interruptionPolicyLog.info(
        "Session deactivated: \(deactivation.userLabel, privacy: .public)",
      )

      guard deactivation.source == .system else {
        // This app asked for the deactivation. Whoever asked owns what happens
        // next; staging a restart here would fight it.
        return
      }

      guard owner.audioRecoveryState.pendingRecording == nil,
        owner.audioRecoveryState.pendingPlayback == nil
      else {
        interruptionPolicyLog.info(
          "Session deactivation already covered by a staged interruption; not re-staging",
        )
        return
      }

      // The platform has already torn the session down, so this behaves like
      // an interruption began: stage pending recovery and stop live I/O.
      await handleInterruptionBegan()
    }

    /// The system's resumption advice. It may resume *playback*. It must never
    /// restart a *recording*: leaving a live recording stops it, and
    /// interruption-driven recording recovery goes through the
    /// pending-recording flow, which requires the caller to still want
    /// recording.
    private func handleResumptionRecommended(_ shouldResume: Bool) async {
      guard shouldResume else {
        interruptionPolicyLog.info(
          "System recommends not resuming; suppressing automatic playback restart",
        )
        owner.audioRecoveryState.playbackResumptionSuppressed = true
        return
      }

      owner.audioRecoveryState.playbackResumptionSuppressed = false

      guard let playback = owner.audioRecoveryState.pendingPlayback else {
        // Deliberately does not consult `pendingRecording`. A recommendation is
        // never sufficient cause to put a microphone back on.
        interruptionPolicyLog.info("System recommends resuming; no pending playback to resume")
        return
      }

      owner.audioRecoveryState.pendingPlayback = nil
      await owner.restartPlayback(from: playback)
    }

    private func handleRouteChange(_ change: AudioRouteChange) async {
      let previousFacts = owner.audioRecoveryState.observedInputFacts
      owner.audioRecoveryState.observedInputFacts = change.inputFacts

      guard owner.isRecording else {
        await recoverPlaybackAfterRouteChange(change)
        return
      }

      interruptionPolicyLog.info(
        "Handling route change: \(change.reason.userLabel, privacy: .public)",
      )

      // A route notification is not by itself a reason to stop the engine and
      // reinstall the tap. Two conditions have to hold together before this can
      // be treated as a no-op: the reported facts must match the last ones
      // observed (nothing about the route moved), *and* the live tap must
      // already be running at those facts (the graph does not need rebuilding).
      // Either alone is insufficient — matching facts with a stale or absent
      // tap still needs a rebuild, and a healthy tap says nothing about a
      // route that has since changed underneath it.
      if let facts = change.inputFacts,
        facts == previousFacts,
        liveTapMatches(facts)
      {
        interruptionPolicyLog.info(
          """
          Route change (\(change.reason.userLabel, privacy: .public)) reports unchanged input \
          facts and the live tap already matches them; keeping the tap installed.
          """,
        )
        return
      }

      guard
        let (configuration, processingFormat): (RecordingConfiguration, AVAudioFormat) =
          owner.state({
            guard let configuration = $0.recordingConfiguration,
              let processingFormat = configuration.processingFormat
            else {
              return nil
            }
            return (configuration, processingFormat)
          })
      else {
        interruptionPolicyLog.error("Missing configuration during route change")
        return
      }

      #if os(macOS)
        if case .systemAudio = configuration.input {
          return
        }
      #endif

      guard change.isInputAvailable else {
        await stopRecordingForInterruption(reason: "No audio input available")
        return
      }

      let cachedFormat = owner.state.withLock { $0.tapConverterInputFormat }
      let formatBefore =
        if let cachedFormat {
          cachedFormat
        } else {
          await owner.withEngineControlQueue { [owner] in
            owner.engine.inputNode.inputFormat(forBus: 0)
          }
        }

      do {
        let installed = try await owner.reinstallTapAsync(
          configuration: configuration,
          processingFormat: processingFormat,
          stopEngine: true,
          overrideResult: owner.reinstallTapOverrideResult(
            configuration: configuration,
            processingFormat: processingFormat,
          ),
        )

        guard owner.isRecording,
          !owner.engineTearingDown.load(ordering: .sequentiallyConsistent),
          let result = installed
        else {
          interruptionPolicyLog.info("Route-change tap reinstall superseded by teardown")
          return
        }

        owner.applyTapInstallResult(result, processingFormat: processingFormat)
        // The reinstall refreshed the staged provenance; mirror it into the
        // observable so quality indicators track the new hardware format.
        owner.activeCaptureFormat = owner.state[locked: \.captureResolution]
        let qualityChange = makeQualityChange(
          from: formatBefore,
          to: result.tapFormat,
          reason: change.reason.userLabel,
        )
        owner.eventSubject.send(
          .recordingInterruption(
            .routeChangeContinuing(event: change, qualityChange: qualityChange),
          ),
        )
      } catch {
        interruptionPolicyLog.error(
          "Failed to reinstall tap after route change: \(error, privacy: .public)",
        )
        await stopRecordingForInterruption(reason: "Route change reconfiguration failed")
      }
    }

    /// Whether a tap is installed and its converter input format is the one
    /// these facts describe.
    ///
    /// This is the "does the graph need rebuilding?" half of the no-op test. It
    /// reads the staged tap state rather than `engine.isRunning`, because the
    /// converter input format is the thing a rate or channel change actually
    /// invalidates.
    private func liveTapMatches(_ facts: AudioInputFacts) -> Bool {
      let tapFormat: AVAudioFormat? = owner.state.withLock { state in
        guard state.installedTapBus != nil else { return nil }
        return state.tapConverterInputFormat
      }
      guard let tapFormat else { return false }
      return facts.matchesCaptureFormat(
        sampleRate: tapFormat.sampleRate,
        channelCount: Int(tapFormat.channelCount),
      )
    }

    private func recoverPlaybackAfterRouteChange(_ change: AudioRouteChange) async {
      guard owner.isPlayback, let resume = owner.capturePlaybackResumeState() else { return }

      let (engineIsRunning, playerIsPlaying) = await owner.withEngineControlQueue {
        [weak owner] in
        guard let owner else { return (false, false) }
        return (owner.engine.isRunning, owner.player.isPlaying)
      }

      if resume.wasPlaying {
        if engineIsRunning, playerIsPlaying { return }
      } else if engineIsRunning {
        return
      }

      interruptionPolicyLog.info(
        "Playback route recovery triggered: \(change.reason.userLabel, privacy: .public)",
      )
      await owner.cancelPlaybackJog()
      await owner.stopPlayback()
      await owner.restartPlayback(from: resume)
    }

    private func handleInterruptionBegan() async {
      let hasRecording = owner.isRecording || owner.recordingLifecycleState.startOperationID != nil
      let hasPlayback = owner.isPlayback
      guard hasRecording || hasPlayback else { return }

      if owner.isRecording {
        // Stash the *request*, not the resolved copy: a `.hardware` recording
        // restarted after an interruption must re-resolve against whatever
        // route exists then, not the one that existed before.
        owner.audioRecoveryState.pendingRecording =
          owner.state.withLock { $0.requestedRecordingConfiguration ?? $0.recordingConfiguration }
          ?? owner.recordingLifecycleState.lastRecordingConfiguration
        await stopRecordingForInterruption(reason: "Audio session interrupted")
      } else if owner.recordingLifecycleState.isStartingRecording {
        owner.recordingLifecycleState.startAbortRequested = true
      }

      if hasPlayback {
        owner.audioRecoveryState.pendingPlayback = owner.capturePlaybackResumeState()
        await owner.cancelPlaybackJog()
        await owner.stopPlayback()
      }
    }

    private func handleInterruptionEnded(shouldResume: Bool) async {
      let recording = owner.audioRecoveryState.pendingRecording
      let playback = owner.audioRecoveryState.pendingPlayback
      let playbackSuppressed = owner.audioRecoveryState.playbackResumptionSuppressed
      owner.audioRecoveryState.clear()

      guard shouldResume else {
        interruptionPolicyLog.info("Interruption ended without permission to resume")
        return
      }

      if let recording {
        await restartRecording(recording)
      } else if let playback {
        guard !playbackSuppressed else {
          interruptionPolicyLog.info(
            "Playback restart suppressed by the system's resumption recommendation",
          )
          return
        }
        await owner.restartPlayback(from: playback)
      }
    }

    private func handleMediaServicesLost() async {
      interruptionPolicyLog.warning("Media services lost; tearing down engine state")
      owner.audioRecoveryState.mediaServicesAreAvailable = false

      if owner.recordingLifecycleState.isStartingRecording {
        owner.recordingLifecycleState.startAbortRequested = true
        return
      }

      if owner.isPlayback {
        owner.audioRecoveryState.pendingPlayback = owner.capturePlaybackResumeState()
        await owner.cancelPlaybackJog()
        await owner.stopPlayback()
      }

      if owner.isRecording {
        // Same as the interruption path: restart from the request so
        // `.hardware` re-resolves against the post-reset route.
        owner.audioRecoveryState.pendingRecording =
          owner.state.withLock { $0.requestedRecordingConfiguration ?? $0.recordingConfiguration }
          ?? owner.recordingLifecycleState.lastRecordingConfiguration
        await stopRecordingForInterruption(reason: "Media services lost")
      } else {
        owner.audioRecoveryState.pendingRecording = nil
      }

      await resetEngineForMediaServices()
    }

    private func handleMediaServicesReset() async {
      interruptionPolicyLog.warning("Media services reset; rebuilding engine state")

      if owner.recordingLifecycleState.isStartingRecording {
        // The in-flight attempt owns graph cleanup. Abort it and let the
        // canonical readiness loop retry after that cleanup completes.
        owner.recordingLifecycleState.startAbortRequested = true
        owner.audioRecoveryState.mediaServicesAreAvailable = true
        return
      }

      await owner.cancelPlaybackJog()
      await resetEngineForMediaServices()
      owner.audioRecoveryState.mediaServicesAreAvailable = true

      let recording = owner.audioRecoveryState.pendingRecording
      let playback = owner.audioRecoveryState.pendingPlayback
      owner.audioRecoveryState.clear()

      if let recording {
        await restartRecording(recording)
      } else if let playback {
        await owner.restartPlayback(from: playback)
      }
    }

    private func stopRecordingForInterruption(reason: String) async {
      guard owner.isRecording || owner.recordingLifecycleState.startOperationID != nil else {
        return
      }

      if !owner.isRecording {
        if owner.recordingLifecycleState.isStartingRecording {
          owner.recordingLifecycleState.startAbortRequested = true
        }
        return
      }

      owner.eventSubject.send(
        .recordingInterruption(.stoppedByInterruption(reason: reason)),
      )

      if owner.recordingLifecycleState.isStartingRecording {
        owner.recordingLifecycleState.startAbortRequested = true
        return
      }

      await owner.recording.gracefulStop()
      owner.eventSubject.send(.recordingFailed)
    }

    private func restartRecording(_ configuration: RecordingConfiguration) async {
      do {
        _ = try await owner.startRecording(configuration: configuration)
      } catch RecordingError.startInProgress {
        // The original bounded start still owns recovery.
      } catch {
        interruptionPolicyLog.error("Recording recovery failed: \(error, privacy: .public)")
        owner.eventSubject.send(.error(error))
        owner.eventSubject.send(.recordingFailed)
      }
    }

    private func resetEngineForMediaServices() async {
      await owner.withEngineControlQueue {
        owner.detachPlaybackJogGraph()
        owner.player.stop()
        owner.engine.stop()
        owner.engine.reset()
        if !owner.engine.attachedNodes.contains(owner.player) {
          owner.engine.attach(owner.player)
        }
      }
    }

    private func makeQualityChange(
      from oldFormat: AVAudioFormat,
      to newFormat: AVAudioFormat,
      reason: String,
    ) -> AIOEngine.AudioQualityChange? {
      let channelsChanged = oldFormat.channelCount != newFormat.channelCount
      let sampleRateChanged = abs(oldFormat.sampleRate - newFormat.sampleRate) > 1
      guard channelsChanged || sampleRateChanged else { return nil }

      return AIOEngine.AudioQualityChange(
        reason: reason,
        previousChannels: oldFormat.channelCount,
        currentChannels: newFormat.channelCount,
        previousSampleRate: oldFormat.sampleRate,
        currentSampleRate: newFormat.sampleRate,
      )
    }
  }
#endif
