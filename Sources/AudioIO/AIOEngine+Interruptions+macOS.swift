// © GoodHatsLLC

#if os(macOS)
  public import AIOAudioSession
  import AIOPlayback
  import AIORecording
  public import AIOEngineCore
  import AIORecordingSupport
  import Atomics
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

      // System-audio capture (Core Audio process tap + private aggregate device)
      // does not use the AVAudioEngine input path, so an input-route change
      // requires no reconfiguration. Reinstalling the input tap here would start
      // the microphone and overwrite the tap converter the capture pump feeds —
      // injecting mic audio into (or silencing) the system-audio recording.
      if case .systemAudio = config.input {
        return
      }

      do {
        let installed = try await reinstallTapAsync(
          configuration: config,
          processingFormat: processingFormat,
          stopEngine: true,
          overrideResult: reinstallTapOverrideResult(
            configuration: config,
            processingFormat: processingFormat,
          ),
        )
        // Post-await liveness re-check: a stop may have completed or begun while
        // the reinstall was suspended on the engine-control queue. See the iOS
        // handler for the full rationale.
        guard isRecording,
          !engineTearingDown.load(ordering: .sequentiallyConsistent),
          let result = installed
        else {
          return
        }
        applyTapInstallResult(result, processingFormat: processingFormat)
        let interruption = RecordingInterruption.routeChangeContinuing(
          event: event,
          qualityChange: nil,
        )
        eventSubject.send(AudioIOEvent.recordingInterruption(interruption))
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

      // A bring-up is in flight: do not reset the engine here — it would race
      // `performWarm` into an orphaned running engine. Abort the start (the
      // PUBLISH-hop reconcile tears the engine down) and stage the restart so
      // `handleMediaServicesReset` replays it.
      if isStartingRecording {
        pendingRecordingRestart = shouldRestartRecording ? configuration : nil
        wantsRecording = false
        startAbortRequested = true
        startAbortRequiresFailureEvent = true
        return
      }

      pendingPlaybackResume = capturePlaybackResumeState()
      if pendingPlaybackResume != nil {
        await cancelPlaybackJog()
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
      await cancelPlaybackJog()
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
      let interruption = RecordingInterruption.stoppedByInterruption(reason: reason)
      eventSubject.send(AudioIOEvent.recordingInterruption(interruption))

      // If a bring-up is in flight, defer teardown to the start path's
      // PUBLISH-hop reconcile (see `AIOEngine.isStartingRecording`); tearing the
      // half-built engine down inline would race `performWarm` into an orphaned
      // running engine. The user-facing interruption event above is still sent.
      if isStartingRecording {
        wantsRecording = false
        startAbortRequested = true
        startAbortRequiresFailureEvent = true
        return
      }

      await gracefulStop()
      eventSubject.send(AudioIOEvent.recordingFailed)
    }

    @MainActor
    private func resetEngineForMediaServices() async {
      await withEngineControlQueue {
        self.detachPlaybackJogGraph()
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
