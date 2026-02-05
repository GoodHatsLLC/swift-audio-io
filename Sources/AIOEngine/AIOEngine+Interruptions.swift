#if !os(macOS) || targetEnvironment(macCatalyst)
  import AVFoundation
  import Foundation
  import SystemLog
  import Tools

  private let log = SystemLog.make()

  extension AIOEngine {

    // MARK: - Route Change & Interruption Handling

    /// Handles an audio route change.
    ///
    /// This method is called when the audio route changes (e.g., headphones are disconnected).
    /// It attempts to continue recording with the new route if possible.
    ///
    /// - Parameter event: The route change details.
    @MainActor
    public func handleRouteChange(event: AudioRouteChangeEvent) async {
      guard isRecording else {
        await handlePlaybackRouteChange(event: event)
        return
      }

      // Prevent re-entrant calls
      let isReEntrant = state {
        if $0.isHandlingRouteChange {
          return true
        } else {
          $0.isHandlingRouteChange = true
          return false
        }
      }
      guard !isReEntrant else {
        log.info("Already handling route change, ignoring duplicate")
        return
      }

      defer { state[locked: \.isHandlingRouteChange] = false }

      log.info("Handling route change: \(String(describing: event.reason), privacy: .public)")

      let session = AVAudioSession.sharedInstance()
      let newInputFormat = runOnEngineControlQueue { [engine = unsafe engine] in
        engine.inputNode.outputFormat(forBus: 0)
      }

      guard
        let (processingFormat, initialFormat): (AVAudioFormat, AVAudioFormat) = state({
          if let currentConfig = $0.recordingConfiguration,
            let processingFormat = currentConfig.processingFormat,
            let initialFormat = $0.initialInputFormat
          {
            return Optional((processingFormat, initialFormat))
          } else {
            return Optional.none
          }
        })
      else {
        log.error("Missing configuration during route change")
        return
      }

      let (cachedInputFormat, cachedOutputFormat, previousFormat) = state.withLock { state in
        (
          state.tapConverterInputFormat, state.tapConverterOutputFormat,
          state.lastInputFormat ?? initialFormat
        )
      }
      let shouldReconfigureTap: Bool = {
        guard let cachedInputFormat, let cachedOutputFormat else { return true }
        return
          !(cachedInputFormat.isEqual(newInputFormat)
          && cachedOutputFormat.isEqual(processingFormat))
      }()

      // Check if we can continue recording
      let canContinue = canContinueRecording(
        from: previousFormat,
        to: newInputFormat,
        processingFormat: processingFormat,
        session: session
      )

      if canContinue {
        // Attempt to continue recording with the new route
        do {
          if shouldReconfigureTap {
            try reconfigureTapForNewRoute(
              newInputFormat: newInputFormat,
              processingFormat: processingFormat
            )
          } else {
            log.info("Skipping tap reconfigure; format unchanged")
          }

          // Notify about quality change if channels or sample rate differ
          let qualityChange = createQualityChange(
            from: previousFormat,
            to: newInputFormat,
            reason: describeRouteChangeReason(event.reason)
          )

          let interruption = RecordingInterruption.routeChangeContinuing(
            event: event,
            qualityChange: qualityChange
          )
          await onRecordingInterruption?(interruption)
          placeState(\.lastInputFormat, newInputFormat)

          log.info("Successfully continued recording after route change")
        } catch {
          log.error("Failed to reconfigure tap after route change: \(error, privacy: .public)")
          Task { @MainActor in
            await handleUnrecoverableInterruption(reason: "Route change reconfiguration failed")
          }
        }
      } else {
        // Cannot continue - stop gracefully
        Task { @MainActor in
          await handleUnrecoverableInterruption(reason: "No suitable audio route available")
        }
      }
    }

    @MainActor
    func handlePlaybackRouteChange(event: AudioRouteChangeEvent) async {
      guard isPlayback else { return }

      let resume = capturePlaybackResumeState()
      guard let resume else { return }

      let (engineIsRunning, playerIsPlaying) = await withEngineControlQueue { [weak self] in
        guard let self else { return (false, false) }
        return unsafe (self.engine.isRunning, self.player.isPlaying)
      }

      if resume.wasPlaying {
        if engineIsRunning && playerIsPlaying { return }
      } else {
        if engineIsRunning { return }
      }

      log.info(
        "Playback route change recovery triggered: \(String(describing: event.reason), privacy: .public)"
      )
      await stopPlayback()
      await restartPlayback(from: resume)
    }

    /// Handles an audio session interruption.
    ///
    /// This method is called when the audio session is interrupted (e.g., by a phone call).
    ///
    /// - Parameters:
    ///   - type: The type of interruption.
    ///   - options: The interruption options.
    @MainActor
    public func handleInterruption(
      type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions?
    ) async {
      switch type {
      case .began:
        guard isRecording else { return }
        log.info("Audio interruption began, stopping recording")
        Task { @MainActor in
          await handleUnrecoverableInterruption(reason: "Audio session interrupted")
        }
      case .ended:
        // For now, we don't automatically resume recording after interruptions
        // This could be enhanced in the future based on options.contains(.shouldResume)
        log.info("Audio interruption ended")
      @unknown default:
        break
      }
    }

    @MainActor
    public func handleMediaServicesLost() async {
      log.warning("Media services lost; tearing down engine state")
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
      log.warning("Media services reset; rebuilding engine state")
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
        unsafe self.player.stop()
        unsafe self.engine.stop()
        unsafe self.engine.reset()
        if unsafe self.engine.attachedNodes.contains(self.player) == false {
          unsafe self.engine.attach(self.player)
        }
      }
    }

    /// Check if recording can continue with the new audio route
    func canContinueRecording(
      from oldFormat: AVAudioFormat,
      to newFormat: AVAudioFormat,
      processingFormat: AVAudioFormat,
      session: AVAudioSession
    ) -> Bool {
      // Check if there's any input available
      guard session.isInputAvailable else {
        log.info("No input available")
        return false
      }

      // Check if we have at least one input channel
      guard newFormat.channelCount > 0 else {
        log.info("New format has no channels")
        return false
      }

      // Check if processing format has valid channels
      guard processingFormat.channelCount > 0 else {
        log.info("Processing format has no channels")
        return false
      }

      // Validate sample rates are reasonable (between 8kHz and 192kHz)
      // AVAudioConverter can handle conversions between standard audio sample rates
      let minSampleRate: Double = 8000.0
      let maxSampleRate: Double = 192000.0
      guard newFormat.sampleRate >= minSampleRate && newFormat.sampleRate <= maxSampleRate else {
        log.info(
          "New format sample rate out of valid range: \(newFormat.sampleRate, privacy: .public)")
        return false
      }

      // We can continue recording with format conversion as long as:
      // 1. Audio input is available
      // 2. Both new and processing formats have valid channels
      // 3. Sample rate is within reasonable bounds for AVAudioConverter
      // The processAudio method will handle format conversion via AVAudioConverter

      log.info(
        """
        Continuing recording with format conversion:
        - Old format: \(oldFormat.channelCount, privacy: .public) channels @ \(oldFormat.sampleRate, privacy: .public) Hz
        - New format: \(newFormat.channelCount, privacy: .public) channels @ \(newFormat.sampleRate, privacy: .public) Hz
        - Processing format: \(processingFormat.channelCount, privacy: .public) channels @ \(processingFormat.sampleRate, privacy: .public) Hz
        """)

      return true
    }

    /// Reconfigure the audio tap for a new route
    func reconfigureTapForNewRoute(
      newInputFormat: AVAudioFormat,
      processingFormat: AVAudioFormat
    ) throws(AIOError) {
      // Remove old tap and stop engine before reconfiguring.
      let currentInputFormat = runOnEngineControlQueue { [weak self] in
        guard let self else { return newInputFormat }
        unsafe self.engine.inputNode.removeTap(onBus: self.state[locked: \.installedTapBus] ?? 0)
        unsafe self.engine.stop()
        return unsafe self.engine.inputNode.outputFormat(forBus: 0)
      }
      state[locked: \.installedTapBus] = nil

      // Validate the format before attempting to install tap.
      // installTap throws an uncatchable NSException if the format is invalid.
      guard currentInputFormat.channelCount > 0 else {
        let session = AVAudioSession.sharedInstance()
        let hardwareFormat = runOnEngineControlQueue {
          unsafe engine.inputNode.inputFormat(forBus: 0)
        }
        let recordPermission = AVAudioApplication.shared.recordPermission
        log.warning(
          """
          Input node has no channels after route change; cannot reconfigure tap.
          recordPermission: \(String(describing: recordPermission), privacy: .public)
          isInputAvailable: \(session.isInputAvailable, privacy: .public)
          outputFormat(forBus: 0): \(currentInputFormat, privacy: .public)
          inputFormat(forBus: 0): \(hardwareFormat, privacy: .public)
          """
        )
        throw AIOError.invalidRecordingConfiguration(
          details: "Input node has no channels after route change (channelCount: 0)")
      }

      guard currentInputFormat.sampleRate > 0 else {
        let session = AVAudioSession.sharedInstance()
        let hardwareFormat = runOnEngineControlQueue {
          unsafe engine.inputNode.inputFormat(forBus: 0)
        }
        let recordPermission = AVAudioApplication.shared.recordPermission
        log.warning(
          """
          Input node has invalid sample rate after route change; cannot reconfigure tap.
          recordPermission: \(String(describing: recordPermission), privacy: .public)
          isInputAvailable: \(session.isInputAvailable, privacy: .public)
          outputFormat(forBus: 0): \(currentInputFormat, privacy: .public)
          inputFormat(forBus: 0): \(hardwareFormat, privacy: .public)
          """
        )
        throw AIOError.invalidRecordingConfiguration(
          details: "Input node has invalid sample rate after route change (sampleRate: 0)")
      }

      // Get tap configuration using the current format (not the pre-stop format)
      guard let currentConfig = state[locked: \.recordingConfiguration],
        let tapConfiguration = currentConfig.tapConfiguration(bus: 0, input: currentInputFormat)
      else {
        throw AIOError.invalidRecordingConfiguration(details: "Cannot create tap configuration")
      }
      guard tapConfiguration.bufferSize > 0 else {
        throw AIOError.invalidRecordingConfiguration(details: "Tap bufferSize is 0")
      }

      // Final validation of the format we'll pass to installTap
      let tapFormat = tapConfiguration.inputAVAudioFormat
      guard tapFormat.channelCount > 0, tapFormat.sampleRate > 0 else {
        throw AIOError.invalidRecordingConfiguration(
          details:
            "Tap format is invalid (channels: \(tapFormat.channelCount), sampleRate: \(tapFormat.sampleRate))"
        )
      }
      guard let tapConverter = AVAudioConverter(from: tapFormat, to: processingFormat) else {
        throw AIOError.formatConversionFailed
      }
      let tapFrameRatio = processingFormat.sampleRate / tapFormat.sampleRate
      let maxTapFrames = max(
        AVAudioFrameCount(ceil(Double(tapConfiguration.bufferSize) * tapFrameRatio)),
        1
      )
      guard
        let tapConvertedBuffer = AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: maxTapFrames
        )
      else {
        throw AIOError.formatConversionFailed
      }
      state {
        $0.tapConverter = tapConverter
        $0.tapConverterInputFormat = tapFormat
        $0.tapConverterOutputFormat = processingFormat
        $0.tapConvertedBuffer = tapConvertedBuffer
      }

      log.info(
        """
        Installing tap with validated format:
        - Current input format: \(currentInputFormat.channelCount, privacy: .public) ch @ \(currentInputFormat.sampleRate, privacy: .public) Hz
        - Tap format: \(tapFormat.channelCount, privacy: .public) ch @ \(tapFormat.sampleRate, privacy: .public) Hz
        """)

      // Install new tap with updated format
      let startResult = runOnEngineControlQueueResult { [weak self] in
        guard let self else { return }
        unsafe self.engine.inputNode.installTap(
          onBus: tapConfiguration.bus,
          bufferSize: tapConfiguration.bufferSize,
          format: tapFormat
        ) { @Sendable buffer, time in
          self.processAudio(
            buffer: buffer,
            time: time,
            to: processingFormat
          )
        }
        try unsafe self.engine.start()
      }
      if case .failure(let error) = startResult {
        throw .engineStartFailed(error: ErrorContext(error))
      }

      state[locked: \.installedTapBus] = tapConfiguration.bus

      log.info("Reconfigured tap for new route: \(currentInputFormat, privacy: .public)")
    }

    /// Handle interruptions that cannot be recovered
    @MainActor
    func handleUnrecoverableInterruption(reason: String) async {
      guard isRecording || wantsRecording else { return }

      log.info("Handling unrecoverable interruption: \(reason, privacy: .public)")

      // Cancel any ongoing reconciliation
      reconciliationTask = nil

      // Notify before stopping
      let interruption = RecordingInterruption.stoppedByInterruption(reason: reason)
      await onRecordingInterruption?(interruption)

      // Stop recording gracefully (also sets wantsRecording = false)
      await gracefulStop()

      // Notify that recording failed (for crash detection/cleanup)
      onRecordingFailed?()
    }

    /// Create quality change event if formats differ
    func createQualityChange(
      from oldFormat: AVAudioFormat,
      to newFormat: AVAudioFormat,
      reason: String
    ) -> AudioQualityChange? {
      let channelsChanged = oldFormat.channelCount != newFormat.channelCount
      let sampleRateChanged = abs(oldFormat.sampleRate - newFormat.sampleRate) > 1

      if channelsChanged || sampleRateChanged {
        return AudioQualityChange(
          reason: reason,
          previousChannels: oldFormat.channelCount,
          currentChannels: newFormat.channelCount,
          previousSampleRate: oldFormat.sampleRate,
          currentSampleRate: newFormat.sampleRate
        )
      }

      return nil
    }

    /// Convert route change reason to human-readable string
    func describeRouteChangeReason(_ reason: AVAudioSession.RouteChangeReason) -> String {
      switch reason {
      case .oldDeviceUnavailable:
        return "Device disconnected"
      case .newDeviceAvailable:
        return "New device connected"
      case .categoryChange:
        return "Audio category changed"
      case .override:
        return "Overridden"
      case .routeConfigurationChange:
        return "Route configuration changed"
      case .wakeFromSleep:
        return "Wake from sleep"
      case .noSuitableRouteForCategory:
        return "No suitable route"
      case .unknown:
        return "Unknown reason"
      @unknown default:
        return "Unknown reason"
      }
    }
  }
#endif
