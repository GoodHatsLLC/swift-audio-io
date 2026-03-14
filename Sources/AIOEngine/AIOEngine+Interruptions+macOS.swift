// © GoodHatsLLC

#if os(macOS)
  import AVFoundation
  import Tools

  extension AIOEngine {
    @MainActor
    public func handleRouteChange(event: AudioRouteChangeEvent) async {
      guard isRecording else { return }

      guard
        let (config, processingFormat): (RecordingConfiguration, AVAudioFormat) = state({
          guard let c = $0.recordingConfiguration, let p = c.processingFormat else { return nil }
          return (c, p)
        })
      else {
        return
      }

      do {
        let result = try reinstallTap(
          configuration: config,
          processingFormat: processingFormat,
          stopEngine: true,
        )
        applyTapInstallResult(result, processingFormat: processingFormat)
        await onRecordingInterruption?(
          .routeChangeContinuing(event: event, qualityChange: nil),
        )
      } catch {
        await handleUnrecoverableInterruption(
          reason: "Route change reconfiguration failed: \(error.localizedDescription)",
        )
      }
    }

    @MainActor
    public func handleInterruption(
      type: AudioInterruptionType,
      options: AudioInterruptionOptions?,
    ) async {
      _ = options
      guard type == .began else { return }
      await handleUnrecoverableInterruption(reason: "Audio interruption")
    }

    @MainActor
    public func handleMediaServicesLost() async {
      let shouldRestartRecording = isRecording || wantsRecording
      let configuration = state[locked: \.recordingConfiguration] ?? lastRecordingConfiguration

      pendingPlaybackResume = capturePlaybackResumeState()
      if pendingPlaybackResume != nil {
        await stopPlayback()
      }

      if shouldRestartRecording {
        pendingRecordingRestart = configuration
        await handleUnrecoverableInterruption(reason: "Media services lost")
      } else {
        pendingRecordingRestart = nil
      }

      await resetEngineForMediaServices()
    }

    @MainActor
    public func handleMediaServicesReset() async {
      await resetEngineForMediaServices()

      if let configuration = pendingRecordingRestart {
        pendingRecordingRestart = nil
        pendingPlaybackResume = nil
        setDesiredRecordingState(true, configuration: configuration)
        return
      }

      if let resume = pendingPlaybackResume {
        pendingPlaybackResume = nil
        await restartPlayback(from: resume)
      }
    }

    @MainActor
    private func handleUnrecoverableInterruption(reason: String) async {
      guard isRecording || wantsRecording else { return }
      reconciliationTask = nil
      await onRecordingInterruption?(.stoppedByInterruption(reason: reason))
      await gracefulStop()
      onRecordingFailed?()
    }

    @MainActor
    private func resetEngineForMediaServices() async {
      await withEngineControlQueue {
        unsafe self.player.stop()
        unsafe self.engine.stop()
        unsafe self.engine.reset()
        if unsafe self.engine.attachedNodes.contains(self.player) == false {
          unsafe self.engine.attach(self.player)
        }
      }
    }
  }
#endif
