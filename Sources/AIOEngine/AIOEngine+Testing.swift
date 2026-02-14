#if !os(macOS) || targetEnvironment(macCatalyst)
  #if DEBUG
    public import AVFoundation
    import Atomics
    import Tools

    @_spi(TESTING)
    extension AIOEngine {
      public struct EngineMetricsSnapshot: Sendable {
        public let tapCallbackCount: Int64
        public let tapCallbackMaxNanos: UInt64
        public let writerUnderruns: Int64
        public let writerStallCount: Int64
        public let receiverUnderruns: Int64
        public let writerDrops: Int64
        public let receiverDrops: Int64
      }

      public nonisolated func debugMetricsSnapshot() -> EngineMetricsSnapshot {
        EngineMetricsSnapshot(
          tapCallbackCount: metrics.tapCallbackCount.load(ordering: .relaxed),
          tapCallbackMaxNanos: metrics.tapCallbackMaxNanos.load(ordering: .relaxed),
          writerUnderruns: metrics.writerUnderruns.load(ordering: .relaxed),
          writerStallCount: metrics.writerStallCount.load(ordering: .relaxed),
          receiverUnderruns: metrics.receiverUnderruns.load(ordering: .relaxed),
          writerDrops: metrics.writerDrops.load(ordering: .relaxed),
          receiverDrops: metrics.receiverDrops.load(ordering: .relaxed)
        )
      }

      public nonisolated func debugBufferCapacities() -> (writer: [Int], receiver: [Int]) {
        let (writerBuffers, receiverBuffers) = state.withLock { state in
          (state.audioBuffers, state.receiverBuffers)
        }
        return (
          writer: writerBuffers?.map(\.capacity) ?? [],
          receiver: receiverBuffers?.map(\.capacity) ?? []
        )
      }

      @MainActor
      public func debugCurrentWriterWrittenSampleTime() -> Int64 {
        writerSession?.control.writtenSampleTime.load(ordering: .relaxed) ?? 0
      }

      @MainActor
      public func debugCurrentRecordingURL() -> URL? {
        state[locked: \.recordingURL]
      }

      public nonisolated func makeTapHandlerForTesting(
        processingFormat: AVAudioFormat
      ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        makeTapHandler(processingFormat: processingFormat)
      }

      @MainActor
      func setReinstallTapOverride(
        _ override: (
          @MainActor (RecordingConfiguration, AVAudioFormat) throws(AIOError) -> TapInstallResult
        )?
      ) {
        testReinstallTapOverride = override
      }

      /// Starts a recording session without touching AVAudioSession or AVAudioEngine.
      /// Intended for integration tests that inject buffers directly.
      @MainActor
      public func startTestRecording(
        configuration: RecordingConfiguration,
        outputURL: URL? = nil,
        bufferSize: AVAudioFrameCount = 1024,
        enableReceivers: Bool = true
      ) throws(AIOError) -> URL {
        guard !isRecording else { throw .alreadyRecording }
        guard let processingFormat = configuration.processingFormat else {
          throw .invalidRecordingConfiguration(details: "(processing format)")
        }

        lastWriteFailure = nil
        lastRecordingConfiguration = configuration

        let url: URL
        if let outputURL {
          url = outputURL
        } else {
          let resolved = try resolveOutputURL(for: configuration, allowExplicitFile: true)
          url = resolved.url
          applyFileProtectionIfNeeded(resolved.protection, to: url)
        }

        let writer = try makeRecordingWriter(url: url, configuration: configuration)

        let sampleRate = Int(processingFormat.sampleRate)
        let channelCount = Int(processingFormat.channelCount)
        guard sampleRate > 0, channelCount > 0 else {
          throw .invalidRecordingConfiguration(details: "Invalid processing format")
        }

        let audioBuffers = makeAudioBuffers(
          sampleRate: sampleRate,
          channelCount: channelCount
        )
        let receiverBuffers =
          enableReceivers
          ? makeAudioBuffers(sampleRate: sampleRate, channelCount: channelCount)
          : nil
        let timingCapacity = max(
          64,
          Int(ceil(Double(sampleRate) / Double(bufferSize))) * 4
        )
        let receiverTiming =
          enableReceivers
          ? SPSCRingBuffer<TimingPacket>(capacity: timingCapacity)
          : nil

        recordingSampleTimeAtomic.store(0, ordering: .relaxed)

        state {
          $0.recordingWriter = writer
          $0.recordingURL = url
          $0.audioBuffers = audioBuffers
          $0.receiverBuffers = receiverBuffers
          $0.receiverTiming = receiverTiming
          $0.recordingConfiguration = configuration
          $0.installedTapBus = nil
        }

        startFileWriteLoop(flushing: audioBuffers, of: processingFormat, to: writer)
        if let receiverBuffers, let receiverTiming, enableReceivers {
          startReceiverLoop(
            buffers: receiverBuffers,
            timing: receiverTiming,
            processingFormat: processingFormat
          )
        }

        isRecording = true
        wantsRecording = true
        return url
      }

      /// Injects PCM samples directly into the writer/receiver buffers for tests.
      public nonisolated func injectTestAudio(
        channels: [[Float]],
        hostTime: UInt64? = nil,
        sourceSampleTime: Int64? = nil,
        sourceSampleRate: Double? = nil
      ) {
        guard !channels.isEmpty else { return }
        let frameLength = channels.map(\.count).min() ?? 0
        guard frameLength > 0 else { return }

        let (audioBuffers, receiverBuffers, timingBuffer) = state.withLock { state in
          (state.audioBuffers, state.receiverBuffers, state.receiverTiming)
        }
        guard let audioBuffers else { return }

        let effectiveChannelCount = min(channels.count, audioBuffers.count)
        guard effectiveChannelCount > 0 else { return }

        let writerAvailable = Self.minimumAvailableWriteFrames(
          channelCount: effectiveChannelCount,
          audioBuffers: audioBuffers,
          limit: frameLength
        )
        let writerCanWrite = writerAvailable >= frameLength

        let receiverCanWrite: Bool
        if let receiverBuffers, let timingBuffer {
          receiverCanWrite =
            timingBuffer.availableToWrite >= 1
            && Self.minimumAvailableWriteFrames(
              channelCount: effectiveChannelCount,
              audioBuffers: receiverBuffers,
              limit: frameLength
            ) >= frameLength
        } else {
          receiverCanWrite = false
        }

        for i in 0..<effectiveChannelCount {
          unsafe channels[i].withUnsafeBufferPointer { buffer in
            if writerCanWrite {
              unsafe audioBuffers[i].write(buffer)
            }
            if receiverCanWrite, let receiverBuffers, i < receiverBuffers.count {
              unsafe receiverBuffers[i].write(buffer)
            }
          }
        }

        if receiverCanWrite, let timingBuffer {
          let startSampleTime = recordingSampleTimeAtomic.load(ordering: .relaxed)
          var packet = TimingPacket(
            startSampleTime: startSampleTime,
            frameCount: frameLength,
            hostTime: hostTime,
            sourceSampleTime: sourceSampleTime,
            sourceSampleRate: sourceSampleRate
          )
          _ = unsafe withUnsafePointer(to: &packet) { pointer in
            unsafe timingBuffer.write(UnsafeBufferPointer(start: pointer, count: 1))
          }
        }

        recordingSampleTimeAtomic.wrappingIncrement(
          by: Int64(frameLength),
          ordering: .relaxed
        )
      }

      /// Deterministically simulates route/input/sample-rate changes while recording.
      ///
      /// Bypasses `AVAudioEngine` graph mutation and only exercises the continuation vs stop
      /// decision logic, interruption callbacks, and stop cleanup.
      @MainActor
      public func simulateRouteChangeForTesting(
        oldFormat: AVAudioFormat,
        newFormat: AVAudioFormat,
        processingFormat: AVAudioFormat,
        isInputAvailable: Bool,
        reason: AVAudioSession.RouteChangeReason = .routeConfigurationChange
      ) async -> Bool {
        guard isRecording || wantsRecording else { return false }

        let canContinue = isFormatViable(
          newFormat,
          processingFormat: processingFormat,
          isInputAvailable: isInputAvailable
        )

        if canContinue {
          let qualityChange = createQualityChange(
            from: oldFormat,
            to: newFormat,
            reason: describeRouteChangeReason(reason)
          )
          let event = AudioRouteChangeEvent(
            reason: reason,
            previousRoute: nil,
            session: AVAudioSession.sharedInstance()
          )
          await onRecordingInterruption?(
            .routeChangeContinuing(
              event: event,
              qualityChange: qualityChange
            ))
          return true
        }

        await handleUnrecoverableInterruption(reason: "No suitable audio route available")
        return false
      }
    }
  #endif
#endif
