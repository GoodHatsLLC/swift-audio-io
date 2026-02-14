#if !os(macOS) || targetEnvironment(macCatalyst)
  import AVFoundation
  import SystemLog
  import Tools
  import os
  private let tapSetupLog = SystemLog.make()

  extension AIOEngine {
    struct TapConversionArtifacts {
      let converter: AVAudioConverter
      let inputFormat: AVAudioFormat
      let convertedBuffer: AVAudioPCMBuffer
    }

    struct TapInstallResult {
      let tapFormat: AVAudioFormat
      let artifacts: TapConversionArtifacts
      let tapConfiguration: TapConfiguration
    }

    func makeTapConversionArtifacts(
      inputFormat: AVAudioFormat,
      processingFormat: AVAudioFormat,
      tapBufferSize: AVAudioFrameCount
    ) throws(AIOError) -> TapConversionArtifacts {
      guard let converter = AVAudioConverter(from: inputFormat, to: processingFormat) else {
        throw AIOError.formatConversionFailed
      }
      let tapFrameRatio = processingFormat.sampleRate / inputFormat.sampleRate
      let maxTapFrames = max(
        AVAudioFrameCount(ceil(Double(tapBufferSize) * tapFrameRatio)),
        1
      )
      guard
        let convertedBuffer = AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: maxTapFrames
        )
      else {
        throw AIOError.formatConversionFailed
      }
      return TapConversionArtifacts(
        converter: converter,
        inputFormat: inputFormat,
        convertedBuffer: convertedBuffer
      )
    }

    /// Reinstalls the audio input tap on the engine.
    ///
    /// This is the single method used by `warm()`, route change handling,
    /// and tap interval updates. All engine graph mutations happen on the
    /// engine control queue in a single dispatch.
    @MainActor
    func reinstallTap(
      configuration: RecordingConfiguration,
      processingFormat: AVAudioFormat,
      stopEngine: Bool
    ) throws(AIOError) -> TapInstallResult {
      #if DEBUG
        if let override = testReinstallTapOverride {
          return try override(configuration, processingFormat)
        }
      #endif

      let installResult = runOnEngineControlQueueResult {
        [weak self] () throws -> TapInstallResult in
        guard let self else { throw AIOError.engineError }

        // 1. Remove existing tap
        let previousBus = self.state[locked: \.installedTapBus] ?? 0
        unsafe self.engine.inputNode.removeTap(onBus: previousBus)
        self.state[locked: \.installedTapBus] = nil

        // 2. Stop engine if requested
        if stopEngine {
          unsafe self.engine.stop()
        }

        // 3. Prepare — updates input node for current hardware
        unsafe self.engine.prepare()

        // 4. Read format — one read, one validation
        let inputFormat = unsafe self.engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
          throw AIOError.audioSessionNotReady(
            details: "Input node has no channels (channelCount: 0)")
        }
        guard inputFormat.sampleRate > 0 else {
          throw AIOError.audioSessionNotReady(
            details: "Input node has invalid sample rate (sampleRate: 0)")
        }

        // 5. Create tap configuration
        guard let tapConfig = configuration.tapConfiguration(bus: 0, input: inputFormat) else {
          throw AIOError.invalidRecordingConfiguration(details: "Cannot create tap configuration")
        }
        guard tapConfig.bufferSize > 0 else {
          throw AIOError.invalidRecordingConfiguration(details: "Tap bufferSize is 0")
        }

        // 6. Install tap with format: nil to match the node's current format
        let tapHandler = self.makeTapHandler(processingFormat: processingFormat)
        unsafe self.engine.inputNode.installTap(
          onBus: tapConfig.bus,
          bufferSize: tapConfig.bufferSize,
          format: nil,
          block: tapHandler
        )

        // 7. Restart engine if we stopped it
        if stopEngine {
          try unsafe self.engine.start()
        }

        // 8. Prepare post-install, read actual format
        unsafe self.engine.prepare()
        let postInstallFormat = unsafe self.engine.inputNode.outputFormat(forBus: 0)
        guard postInstallFormat.channelCount > 0, postInstallFormat.sampleRate > 0 else {
          throw AIOError.invalidRecordingConfiguration(
            details:
              "Format invalid after tap install (channels: \(postInstallFormat.channelCount), sampleRate: \(postInstallFormat.sampleRate))"
          )
        }

        // 8. Create conversion artifacts from the actual post-install format
        let artifacts = try self.makeTapConversionArtifacts(
          inputFormat: postInstallFormat,
          processingFormat: processingFormat,
          tapBufferSize: tapConfig.bufferSize
        )

        return TapInstallResult(
          tapFormat: postInstallFormat,
          artifacts: artifacts,
          tapConfiguration: tapConfig
        )
      }

      switch installResult {
      case .success(let result):
        tapSetupLog.info("Tap installed: \(result.tapFormat, privacy: .public)")
        return result
      case .failure(let error):
        throw (error as? AIOError) ?? .engineStartFailed(error: ErrorContext(error))
      }
    }

    /// Applies tap install results to engine state.
    func applyTapInstallResult(_ result: TapInstallResult, processingFormat: AVAudioFormat) {
      state {
        $0.tapConverter = result.artifacts.converter
        $0.tapConverterInputFormat = result.artifacts.inputFormat
        $0.tapConverterOutputFormat = processingFormat
        $0.tapConvertedBuffer = result.artifacts.convertedBuffer
        $0.installedTapBus = result.tapConfiguration.bus
      }
    }
  }
#endif
