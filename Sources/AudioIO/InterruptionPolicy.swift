// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOEngineCore
  import AIOPlayback
  import AIORecording
  import AIORecordingSupport
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
      }
    }

    private func handleRouteChange(_ change: AudioRouteChange) async {
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
        owner.audioRecoveryState.pendingRecording =
          owner.state[locked: \.recordingConfiguration]
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
      owner.audioRecoveryState.clear()

      guard shouldResume else {
        interruptionPolicyLog.info("Interruption ended without permission to resume")
        return
      }

      if let recording {
        await restartRecording(recording)
      } else if let playback {
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
        owner.audioRecoveryState.pendingRecording =
          owner.state[locked: \.recordingConfiguration]
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

      await RecordingLifecycle(owner: owner).gracefulStop()
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
