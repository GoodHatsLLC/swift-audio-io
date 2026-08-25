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
  ///
  /// The recording rule is continuity: a running recording is *paused* by the
  /// events the system forces (an interruption, media services going away)
  /// and *adapted* through everything else (route changes, a route with no
  /// input, a rebuild that fails). Nothing here stops a recording. Playback
  /// follows the platform's advice, with one named exception for the route
  /// the user physically unplugged.
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
        await handleSessionActivated()
      case .sessionDeactivated(let deactivation):
        await handleSessionDeactivated(deactivation)
      case .resumptionRecommended(let shouldResume):
        await handleResumptionRecommended(shouldResume)
      }
    }

    // MARK: - Session state channel (iOS 27)

    /// iOS 27 surfaces one interruption through *both*
    /// `interruptionBegan`/`Ended` and `didBecomeInactive`/`didBecomeActive`.
    /// The dedup rule: interruption events are the trigger, and a
    /// session-state event only acts when nothing is already paused or staged.
    private func handleSessionDeactivated(
      _ deactivation: AudioSessionDeactivation,
    ) async {
      interruptionPolicyLog.info(
        "Session deactivated: \(deactivation.userLabel, privacy: .public)",
      )

      guard deactivation.source == .system else {
        // This app asked for the deactivation. Whoever asked owns what happens
        // next; pausing here would fight it.
        return
      }

      guard owner.recordingPause == nil,
        owner.audioRecoveryState.pendingPlayback == nil
      else {
        interruptionPolicyLog.info(
          "Session deactivation already covered by an interruption; not re-staging",
        )
        return
      }

      await handleInterruptionBegan()
    }

    /// Applied-state reconciliation is the environment manager's job. For a
    /// recording paused by an interruption, the session coming back is the
    /// cue to try resuming — the interruption channel usually says so first,
    /// and this is the backstop when it does not.
    private func handleSessionActivated() async {
      interruptionPolicyLog.info("Audio session became active")
      if let pause = owner.recordingPause, case .interruption = pause.reason {
        await owner.resumeRecording()
      }
    }

    /// The system's resumption advice. It may resume *playback*; it never
    /// touches a recording, which has its own resume path driven by the
    /// interruption ending.
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
        interruptionPolicyLog.info("System recommends resuming; no pending playback to resume")
        return
      }

      owner.audioRecoveryState.pendingPlayback = nil
      await owner.restartPlayback(from: playback)
    }

    // MARK: - Route changes

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

      if let pause = owner.recordingPause {
        // A paused recording treats a route event as a chance to resume, if
        // the route can feed it. An interruption pause waits for its own
        // ending signal, and a media-services pause for the reset.
        guard case .sourceUnavailable = pause.reason, change.isInputAvailable else { return }
        await owner.resumeRecording()
        return
      }

      // A route notification is not by itself a reason to stop the engine and
      // reinstall the tap. Two conditions have to hold together before this can
      // be treated as a no-op: the reported facts must match the last ones
      // observed (nothing about the route moved), *and* the live tap must
      // already be running at those facts (the graph does not need rebuilding).
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

      guard change.isInputAvailable else {
        // The source is gone, the recording is not: it waits for a route.
        await owner.pauseRecording(reason: .sourceUnavailable("No audio input available"))
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
          owner.recordingPause == nil,
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
        let qualityChange = AIOEngine.AudioQualityChange.between(
          formatBefore,
          result.tapFormat,
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
        // An engine limitation is not the OS forcing a stop. The recording
        // waits for a route it can be rebuilt on.
        await owner.pauseRecording(
          reason: .sourceUnavailable("Route change reconfiguration failed: \(error)"),
        )
      }
    }

    /// Whether a tap is installed and its converter input format is the one
    /// these facts describe.
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

    // MARK: - Playback route changes

    private func recoverPlaybackAfterRouteChange(_ change: AudioRouteChange) async {
      guard owner.isPlayback, let resume = owner.capturePlaybackResumeState() else { return }

      // The one route change that pauses on purpose: the user pulled the
      // headphones. That is a user signal, not an environment change, so it
      // gets the platform's conventional answer unless the caller opted out.
      if owner.playbackRouteDisconnectBehavior == .pause,
        change.reason == .deviceDisconnected,
        resume.wasPlaying,
        change.previousRoute?.outputs.contains(where: Self.isPersonalListeningPort) == true
      {
        interruptionPolicyLog.info("Personal listening route disconnected; pausing playback")
        owner.pausePlayback()
        return
      }

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

    /// Whether an output port is one a person listens to privately — the
    /// ports whose disappearance means "the listener unplugged".
    static func isPersonalListeningPort(_ port: AudioPortSnapshot) -> Bool {
      let type = port.type.lowercased()
      return type.contains("headphone")
        || type.contains("bluetooth")
        || type.contains("headset")
        || type.contains("usb")
    }

    // MARK: - Interruptions

    private func handleInterruptionBegan() async {
      let hasRecording = owner.isRecording || owner.recordingLifecycleState.startOperationID != nil
      let hasPlayback = owner.isPlayback
      guard hasRecording || hasPlayback else { return }

      if owner.isRecording {
        await owner.pauseRecording(reason: .interruption)
      } else if owner.recordingLifecycleState.isStartingRecording {
        // The in-flight start cannot finish under an interruption; the caller
        // owns the retry.
        owner.recordingLifecycleState.startAbortRequested = true
      }

      if hasPlayback {
        owner.audioRecoveryState.pendingPlayback = owner.capturePlaybackResumeState()
        await owner.cancelPlaybackJog()
        await owner.stopPlayback()
      }
    }

    private func handleInterruptionEnded(shouldResume: Bool) async {
      let playback = owner.audioRecoveryState.pendingPlayback
      let playbackSuppressed = owner.audioRecoveryState.playbackResumptionSuppressed
      owner.audioRecoveryState.clear()

      // The recording was armed by the user, so its intent is known.
      // `shouldResume` is the system's advice about *playback*; for a
      // recording it only changes how soon the attempt is likely to succeed.
      if owner.recordingPause != nil {
        if !shouldResume {
          interruptionPolicyLog.info(
            "Interruption ended without resume advice; the recording still tries to resume",
          )
        }
        await owner.resumeRecording()
      }

      guard shouldResume else {
        interruptionPolicyLog.info("Interruption ended without permission to resume playback")
        return
      }

      if let playback {
        guard !playbackSuppressed else {
          interruptionPolicyLog.info(
            "Playback restart suppressed by the system's resumption recommendation",
          )
          return
        }
        await owner.restartPlayback(from: playback)
      }
    }

    // MARK: - Media services

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
        await owner.pauseRecording(reason: .mediaServicesLost)
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

      let playback = owner.audioRecoveryState.pendingPlayback
      owner.audioRecoveryState.clear()

      if owner.recordingPause != nil {
        await owner.resumeRecording()
      }
      if let playback {
        await owner.restartPlayback(from: playback)
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
  }
#endif
