// © GoodHatsLLC

#if os(iOS)
  public import AIOAudioSession
  import AIOPlayback
  import AIORecording
  import AIOSupport
  public import AIOEngineCore
  import AIORecordingSupport
  import Atomics
  public import AVFoundation
  import Foundation
  import os
  import Tools

  private let log = SystemLog.make()

  extension AIOEngine {
    // MARK: - Route Change & Interruption Handling

    /// Handles an audio route change during recording by reinstalling the tap.
    ///
    /// If the tap cannot be reinstalled (e.g. no input available, invalid format),
    /// recording is stopped gracefully.
    @MainActor
    public func handleRouteChange(event: AudioRouteChangeEvent) async {
      guard isRecording else {
        await handlePlaybackRouteChange(event: event)
        return
      }

      log.info("Handling route change: \(String(describing: event.reason), privacy: .public)")

      // Use the input-availability already captured in the route-change event
      // snapshot rather than re-reading `AVAudioSession.isInputAvailable` live
      // (a mediaserverd XPC round-trip) on the main actor.
      guard event.session.isInputAvailable else {
        await handleUnrecoverableInterruption(reason: "No audio input available")
        return
      }

      guard
        let (config, processingFormat): (RecordingConfiguration, AVAudioFormat) = state({
          guard let c = $0.recordingConfiguration, let p = c.processingFormat else { return nil }
          return (c, p)
        })
      else {
        log.error("Missing configuration during route change")
        return
      }

      // Snapshot format before reinstall for quality-change detection
      let formatBefore =
        state.withLock { $0.tapConverterInputFormat }
        ?? runOnEngineControlQueue { [engine = unsafe engine] in
          engine.inputNode.inputFormat(forBus: 0)
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

        // Post-await liveness re-check. The reinstall suspended on the
        // engine-control queue; while suspended a stop could have COMPLETED
        // (`isRecording` now false) or BEGUN (`engineTearingDown` now true, even
        // if `isRecording` hasn't flipped yet because gracefulStop sets it false
        // only after its drain await). In either case the stop owns the graph —
        // skip without resurrecting converter state or emitting a spurious
        // `routeChangeContinuing` event. A `nil` result is the in-queue guard
        // having already bailed.
        guard isRecording,
          !engineTearingDown.load(ordering: .sequentiallyConsistent),
          let result = installed
        else {
          log.info("Route-change tap reinstall superseded by teardown; skipping")
          return
        }

        applyTapInstallResult(result, processingFormat: processingFormat)

        let qualityChange = createQualityChange(
          from: formatBefore,
          to: result.tapFormat,
          reason: describeRouteChangeReason(event.reason),
        )
        let interruption = RecordingInterruption.routeChangeContinuing(
          event: event,
          qualityChange: qualityChange,
        )
        eventSubject.send(AudioIOEvent.recordingInterruption(interruption))

        log.info("Continued recording after route change")
      } catch {
        log.error("Failed to reinstall tap after route change: \(error, privacy: .public)")
        await handleUnrecoverableInterruption(reason: "Route change reconfiguration failed")
      }
    }

    @MainActor
    func handlePlaybackRouteChange(event: AudioRouteChangeEvent) async {
      guard isPlayback else { return }

      let resume = capturePlaybackResumeState()
      guard let resume else { return }

      let (engineIsRunning, playerIsPlaying) = await withEngineControlQueue { [weak self] in
        guard let self else { return (false, false) }
        return unsafe (engine.isRunning, player.isPlaying)
      }

      if resume.wasPlaying {
        if engineIsRunning, playerIsPlaying { return }
      } else {
        if engineIsRunning { return }
      }

      log.info(
        "Playback route change recovery triggered: \(String(describing: event.reason), privacy: .public)",
      )
      await cancelPlaybackJog()
      await stopPlayback()
      await restartPlayback(from: resume)
    }

    /// Handles an audio session interruption.
    ///
    /// On `.began` while recording is active or desired, the current recording
    /// configuration is staged into ``AIOEngine/pendingRecordingRestart`` *before*
    /// the engine is torn down, so recording can be resumed once the interruption
    /// ends. On `.ended`, recording is resumed **only** when the system reports
    /// `AVAudioSession.InterruptionOptions.shouldResume` — matching Apple's
    /// guidance that `.shouldResume` is advisory and resume must be gated on it.
    /// Resume reuses the same ``AIOEngine/setDesiredRecordingState(_:configuration:)``
    /// path as media-services recovery.
    @MainActor
    public func handleInterruption(
      type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions?,
    ) async {
      switch type {
      case .began:
        guard isRecording || wantsRecording else { return }
        log.info("Audio interruption began, stopping recording")
        pendingRecordingRestart =
          state[locked: \.recordingConfiguration] ?? lastRecordingConfiguration
        await handleUnrecoverableInterruption(reason: "Audio session interrupted")
      case .ended:
        guard let configuration = pendingRecordingRestart else {
          log.info("Audio interruption ended")
          return
        }
        pendingRecordingRestart = nil

        guard options?.contains(.shouldResume) == true else {
          log.info("Audio interruption ended without shouldResume; not resuming recording")
          return
        }

        log.info("Audio interruption ended with shouldResume; resuming recording")
        setDesiredRecordingState(true, configuration: configuration)
      @unknown default:
        break
      }
    }

    @MainActor
    public func handleMediaServicesLost() async {
      log.warning("Media services lost; tearing down engine state")
      let shouldRestartRecording = isRecording || wantsRecording
      let configuration = state[locked: \.recordingConfiguration] ?? lastRecordingConfiguration

      // A bring-up is in flight: do not reset the engine here — it would race
      // `performWarm` into an orphaned running engine. Abort the start (the
      // PUBLISH-hop reconcile tears the engine down) and stage the restart so
      // `handleMediaServicesReset` replays it, exactly as for an established
      // recording.
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
      log.warning("Media services reset; rebuilding engine state")
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
    func resetEngineForMediaServices() async {
      await withEngineControlQueue {
        if let jogSourceNode = unsafe self.jogSourceNode {
          unsafe self.engine.disconnectNodeOutput(jogSourceNode)
          unsafe self.engine.detach(jogSourceNode)
          unsafe self.jogSourceNode = nil
        }
        unsafe self.player.stop()
        unsafe self.engine.stop()
        unsafe self.engine.reset()
        if unsafe self.engine.attachedNodes.contains(self.player) == false {
          unsafe self.engine.attach(self.player)
        }
      }
    }

    // MARK: - Helpers

    /// Checks whether a new audio format is viable for continued recording.
    /// Used by `simulateRouteChangeForTesting()`.
    func isFormatViable(
      _ format: AVAudioFormat,
      processingFormat: AVAudioFormat,
      isInputAvailable: Bool,
    ) -> Bool {
      guard isInputAvailable else { return false }
      guard format.channelCount > 0 else { return false }
      guard format.sampleRate >= 8000, format.sampleRate <= 192_000 else { return false }
      guard AVAudioConverter(from: format, to: processingFormat) != nil else { return false }
      return true
    }

    @MainActor
    func handleUnrecoverableInterruption(reason: String) async {
      guard isRecording || wantsRecording else { return }

      log.info("Handling unrecoverable interruption: \(reason, privacy: .public)")
      reconciliationTask = nil

      let interruption = RecordingInterruption.stoppedByInterruption(reason: reason)
      eventSubject.send(AudioIOEvent.recordingInterruption(interruption))

      // If a bring-up is in flight, the engine is half-built and tearing it down
      // inline would race `performWarm` into an orphaned running engine. Defer:
      // signal the abort (the start path's PUBLISH-hop reconcile performs the
      // `gracefulStop()` + `recordingFailed`). The user-facing interruption
      // event above is still emitted.
      if isStartingRecording {
        wantsRecording = false
        startAbortRequested = true
        startAbortRequiresFailureEvent = true
        return
      }

      await gracefulStop()
      eventSubject.send(AudioIOEvent.recordingFailed)
    }

    func createQualityChange(
      from oldFormat: AVAudioFormat,
      to newFormat: AVAudioFormat,
      reason: String,
    ) -> AudioQualityChange? {
      let channelsChanged = oldFormat.channelCount != newFormat.channelCount
      let sampleRateChanged = abs(oldFormat.sampleRate - newFormat.sampleRate) > 1

      if channelsChanged || sampleRateChanged {
        return AudioQualityChange(
          reason: reason,
          previousChannels: oldFormat.channelCount,
          currentChannels: newFormat.channelCount,
          previousSampleRate: oldFormat.sampleRate,
          currentSampleRate: newFormat.sampleRate,
        )
      }

      return nil
    }

    func describeRouteChangeReason(_ reason: AVAudioSession.RouteChangeReason) -> String {
      switch reason {
      case .oldDeviceUnavailable: "Device disconnected"
      case .newDeviceAvailable: "New device connected"
      case .categoryChange: "Audio category changed"
      case .override: "Overridden"
      case .routeConfigurationChange: "Route configuration changed"
      case .wakeFromSleep: "Wake from sleep"
      case .noSuitableRouteForCategory: "No suitable route"
      case .unknown: "Unknown reason"
      @unknown default: "Unknown reason"
      }
    }
  }
#endif
