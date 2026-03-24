// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOAudioSession
  import AIOSupport
  package import AIOEngineCore
  package import AIORecordingSupport
  package import AVFoundation
  import os
  import Tools

  private let tapSetupLog = SystemLog.make()

  extension AIOEngine {
    func makeTapConversionArtifacts(
      inputFormat: AVAudioFormat,
      processingFormat: AVAudioFormat,
      tapBufferSize: AVAudioFrameCount,
    ) throws(AIOError) -> TapConversionArtifacts {
      guard let converter = AVAudioConverter(from: inputFormat, to: processingFormat) else {
        throw AIOError.formatConversionFailed
      }
      let tapFrameRatio = processingFormat.sampleRate / inputFormat.sampleRate
      let maxTapFrames = max(
        AVAudioFrameCount(ceil(Double(tapBufferSize) * tapFrameRatio)),
        1,
      )
      guard
        let convertedBuffer = AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: maxTapFrames,
        )
      else {
        throw AIOError.formatConversionFailed
      }
      return TapConversionArtifacts(
        converter: converter,
        inputFormat: inputFormat,
        convertedBuffer: convertedBuffer,
      )
    }

    /// Reinstalls the audio input tap on the engine.
    ///
    /// This is the single method used by `warm()`, route change handling,
    /// and tap interval updates. All engine graph mutations happen on the
    /// engine control queue in a single dispatch.
    @MainActor
    package func reinstallTap(
      configuration: RecordingConfiguration,
      processingFormat: AVAudioFormat,
      stopEngine: Bool,
    ) throws(AIOError) -> TapInstallResult {
      #if DEBUG
        if let override = testReinstallTapOverride {
          return try override(configuration, processingFormat)
        }
      #endif

      let installResult = runOnEngineControlQueueResult {
        [weak self] () throws -> TapInstallResult in
        guard let self else { throw AIOError.engineError }
        dispatchPrecondition(condition: .onQueue(self.engineControlQueue))

        // 1. Remove existing tap
        let previousBus = self.state[locked: \.installedTapBus] ?? 0
        unsafe self.engine.inputNode.removeTap(onBus: previousBus)
        self.state[locked: \.installedTapBus] = nil

        // 2. Stop and reset engine if requested — reset() clears cached node
        //    formats so that prepare() queries the current hardware (critical
        //    after a route change where the sample rate may differ).
        if stopEngine {
          unsafe self.engine.stop()
          unsafe self.engine.reset()
          if unsafe !self.engine.attachedNodes.contains(self.player) {
            unsafe self.engine.attach(self.player)
          }
        }

        // 3. Prepare — updates input node for current hardware
        unsafe self.engine.prepare()

        // 4. Read format — one read, one validation
        let inputFormat = unsafe self.engine.inputNode.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
          throw AIOError.audioSessionNotReady(
            details: "Input node has no channels (channelCount: 0)",
          )
        }
        guard inputFormat.sampleRate > 0 else {
          throw AIOError.audioSessionNotReady(
            details: "Input node has invalid sample rate (sampleRate: 0)",
          )
        }

        // 5. Create tap configuration
        guard let tapConfig = configuration.tapConfiguration(bus: 0, input: inputFormat) else {
          throw AIOError.invalidRecordingConfiguration(details: "Cannot create tap configuration")
        }
        guard tapConfig.bufferSize > 0 else {
          throw AIOError.invalidRecordingConfiguration(details: "Tap bufferSize is 0")
        }

        // 6. Install tap with format: nil to match the node's current format
        unsafe self.engine.inputNode.installTap(
          onBus: tapConfig.bus,
          bufferSize: tapConfig.bufferSize,
          format: inputFormat,
          block: { @Sendable [self] buffer, time in
            self.processAudio(
              buffer: buffer,
              time: time,
              to: processingFormat,
            )
          },
        )

        // 7. Prepare post-install, read actual format
        unsafe self.engine.prepare()
        let postInstallFormat = unsafe self.engine.inputNode.inputFormat(forBus: 0)
        guard postInstallFormat.channelCount > 0, postInstallFormat.sampleRate > 0 else {
          throw AIOError.invalidRecordingConfiguration(
            details:
              "Format invalid after tap install (channels: \(postInstallFormat.channelCount), sampleRate: \(postInstallFormat.sampleRate))",
          )
        }
        guard postInstallFormat.isEqual(inputFormat) else {
          throw AIOError.invalidRecordingConfiguration(
            details:
              "Format changed after tap install (channels: \(inputFormat.channelCount), sampleRate: \(inputFormat.sampleRate)) -> (channels: \(postInstallFormat.channelCount), sampleRate: \(postInstallFormat.sampleRate))",
          )
        }

        // 8. Create conversion artifacts from the actual post-install format
        let artifacts = try self.makeTapConversionArtifacts(
          inputFormat: postInstallFormat,
          processingFormat: processingFormat,
          tapBufferSize: tapConfig.bufferSize,
        )

        let result = TapInstallResult(
          tapFormat: postInstallFormat,
          artifacts: artifacts,
          tapConfiguration: tapConfig,
        )

        // 9. Apply converter state before starting the engine so that
        //    processAudio sees the correct converter from the very first
        //    buffer delivered after start.
        self.applyTapInstallResult(result, processingFormat: processingFormat)

        // 10. Restart engine if we stopped it
        if stopEngine {
          try unsafe self.engine.start()
        }

        return result
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
    ///
    /// Thread Domain: engineControl (called from `reinstallTap` on the engine
    /// control queue, or from `warm()` on MainActor after the queue dispatch).
    package func applyTapInstallResult(_ result: TapInstallResult, processingFormat: AVAudioFormat)
    {
      let wrapped = state { state -> Transferring<TapSnapshot> in
        state.tapConverter = result.artifacts.converter
        state.tapConverterInputFormat = result.artifacts.inputFormat
        state.tapConverterOutputFormat = processingFormat
        state.tapConvertedBuffer = result.artifacts.convertedBuffer
        state.installedTapBus = result.tapConfiguration.bus
        return Transferring(
          TapSnapshot(
            audioBuffers: state.audioBuffers,
            receiverBuffers: state.receiverBuffers,
            receiverTiming: state.receiverTiming,
            converter: state.tapConverter,
            converterInputFormat: state.tapConverterInputFormat,
            converterOutputFormat: state.tapConverterOutputFormat,
            convertedBuffer: state.tapConvertedBuffer,
          ),
        )
      }
      recordingInfrastructure.tapSnapshotLock.withLock { $0 = wrapped.value }
    }
  }
#endif
