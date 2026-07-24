// © GoodHatsLLC

#if os(iOS)
  #if DEBUG
    public import AIOAudioSession
    public import AIOEngineCore
    import AIORecording
    import Atomics
    public import AVFoundation
    import Tools
    import AIORecordingSupport

    /// Synthetic capture source for buffer-injection tests. It deliberately
    /// owns no platform graph, but participates in the same lifecycle contract
    /// as production sources.
    private final class TestingCaptureBackend: RecordingCaptureBackend, @unchecked Sendable {
      private weak var owner: AIOEngine?

      init(owner: AIOEngine) {
        self.owner = owner
      }

      func start() throws(RecordingError) {}

      @MainActor
      func stop(mode _: RecordingCaptureStopMode) {
        owner?.testEngineTeardownOverride?()
        _ = owner?.state.consume(\.installedTapBus)
      }

      @MainActor
      func cleanup() {}
    }

    @_spi(TESTING)
    extension AIOEngine {
      public struct WriterDrainTestHandle: Sendable {
        public let id: UUID
        public let fileURL: URL
        private let control: WriterControl
        private let closeCountValue: @Sendable () -> Int
        private let closed: AsyncContinuation<Void>

        fileprivate init(
          id: UUID,
          fileURL: URL,
          control: WriterControl,
          closeCountValue: @escaping @Sendable () -> Int,
          closed: AsyncContinuation<Void>,
        ) {
          self.id = id
          self.fileURL = fileURL
          self.control = control
          self.closeCountValue = closeCountValue
          self.closed = closed
        }

        public var stopRequested: Bool {
          control.stopRequested.load(ordering: .relaxed)
        }

        public var targetSampleTime: Int64 {
          control.targetSampleTime.load(ordering: .relaxed)
        }

        public var writtenSampleTime: Int64 {
          control.writtenSampleTime.load(ordering: .relaxed)
        }

        public func closeCount() -> Int {
          closeCountValue()
        }

        public func signalDrain() async {
          await control.drainSignal.signal()
        }

        public func waitUntilClosed() async {
          await closed()
        }
      }

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
          receiverDrops: metrics.receiverDrops.load(ordering: .relaxed),
        )
      }

      public nonisolated func debugBufferCapacities() -> (writer: [Int], receiver: [Int]) {
        let (writerBuffers, receiverBuffers) = state.withLock { state in
          (state.audioBuffers, state.receiverBuffers)
        }
        return (
          writer: writerBuffers?.map(\.capacity) ?? [],
          receiver: receiverBuffers?.map(\.capacity) ?? [],
        )
      }

      @MainActor
      public func debugCurrentWriterWrittenSampleTime() -> Int64 {
        recordingLifecycleState.writerSession?.control.writtenSampleTime.load(
          ordering: .relaxed,
        ) ?? 0
      }

      @MainActor
      public func debugCurrentRecordingURL() -> URL? {
        state[locked: \.recordingURL]
      }

      @MainActor
      public func debugStartQueuedWriterDrainForTesting(
        fileURL: URL,
        targetSampleTime: Int64 = 1,
        writtenSampleTime: Int64 = 0,
      ) -> WriterDrainTestHandle {
        recordingSampleTimeAtomic.store(targetSampleTime, ordering: .relaxed)
        let control = WriterControl()
        let closed = AsyncContinuation<Void>()
        control.writtenSampleTime.store(writtenSampleTime, ordering: .relaxed)
        let writer = TestingRecordingFileWriter(fileURL: fileURL, closed: closed)
        let session = WriterSession(
          id: UUID(),
          control: control,
          writer: writer,
          fileURL: fileURL,
        )
        RecordingLifecycle(owner: self).writer.enqueueDrain(for: session)
        return WriterDrainTestHandle(
          id: session.id,
          fileURL: fileURL,
          control: control,
          closeCountValue: { writer.closeCount() },
          closed: closed,
        )
      }

      @MainActor
      public func debugDrainingWriterSessionIDsForTesting() -> [UUID] {
        recordingLifecycleState.drainingWriterSessions.map(\.id)
      }

      public nonisolated func debugDrainRecordingCallbacksForTesting() async {
        await recordingCallbackTasks.drain()
      }

      @MainActor
      internal func setReinstallTapOverride(
        _ override: (
          @MainActor (RecordingConfiguration, AVAudioFormat) throws(RecordingError) ->
            TapInstallResult
        )?,
      ) {
        testReinstallTapOverride = override
      }

      @MainActor
      public func debugInstallSuccessfulTapReinstallOverrideForTesting(
        tapFormat: AVAudioFormat? = nil,
        onCall: (@MainActor @Sendable () -> Void)? = nil,
      ) {
        setReinstallTapOverride { _, processingFormat throws(RecordingError) in
          onCall?()
          let resolvedTapFormat = tapFormat ?? processingFormat
          guard let converter = AVAudioConverter(from: resolvedTapFormat, to: processingFormat)
          else {
            throw RecordingError.formatConversionFailed
          }
          guard
            let buffer = AVAudioPCMBuffer(
              pcmFormat: processingFormat,
              frameCapacity: 1_024,
            )
          else {
            throw RecordingError.formatConversionFailed
          }

          let artifacts = TapConversionArtifacts(
            converter: converter,
            inputFormat: resolvedTapFormat,
            convertedBuffer: buffer,
          )
          let tapConfig = TapConfiguration(
            bus: 0,
            inputFormat: resolvedTapFormat,
            outputFormat: processingFormat,
            bufferSize: 1_024,
          )
          return TapInstallResult(
            tapFormat: resolvedTapFormat,
            artifacts: artifacts,
            tapConfiguration: tapConfig,
          )
        }
      }

      @MainActor
      public func debugClearTapReinstallOverrideForTesting() {
        setReinstallTapOverride(nil)
      }

      /// Bypasses the real `AVAudioEngine` graph teardown inside the recording stop
      /// paths (`gracefulStop()` and `hardStop()`), which crashes the iOS Simulator
      /// audio HAL. Recording stop/cleanup and the `isRecording`
      /// transitions still run, so interruption, resume, and stop logic can be
      /// exercised without a real audio device.
      ///
      /// - Parameter onTeardown: Optional probe invoked in place of the real teardown,
      ///   letting a test assert the teardown path was reached.
      @MainActor
      public func debugBypassEngineTeardownForTesting(
        onTeardown: (@MainActor @Sendable () -> Void)? = nil,
      ) {
        testEngineTeardownOverride = { onTeardown?() }
      }

      @MainActor
      public func debugClearEngineTeardownOverrideForTesting() {
        testEngineTeardownOverride = nil
      }

      /// Forces the engine-teardown serialization sentinel
      /// (``AIOEngine/engineTearingDown``) for tests, simulating a teardown that
      /// has set the flag before its on-queue work has cleared state. Used to
      /// drive the on-queue reinstall guard deterministically without racing a
      /// real `gracefulStop()`.
      @MainActor
      public func debugSetEngineTearingDownForTesting(_ value: Bool) {
        engineTearingDown.store(value, ordering: .sequentiallyConsistent)
      }

      /// The currently installed tap bus, or `nil` when no tap is installed.
      /// Lets a test assert that a superseded reinstall left no tap behind.
      @MainActor
      public func debugInstalledTapBusForTesting() -> Int? {
        state[locked: \.installedTapBus]
      }

      /// Starts a recording session without touching AVAudioSession or AVAudioEngine.
      /// Intended for integration tests that inject buffers directly.
      @MainActor
      public func startTestRecording(
        configuration: RecordingConfiguration,
        outputURL: URL? = nil,
        bufferSize: AVAudioFrameCount = 1024,
        enableReceivers: Bool = true,
      ) throws(RecordingError) -> URL {
        guard !isRecording else { throw .alreadyRecording }
        let lifecycle = RecordingLifecycle(owner: self)
        try lifecycle.capture.validateRecordingChannelCapacity(for: configuration)
        guard let processingFormat = configuration.processingFormat else {
          throw .invalidConfiguration(details: "(processing format)")
        }

        recordingLifecycleState.lastWriteFailure = nil
        recordingLifecycleState.lastRecordingConfiguration = configuration

        let url: URL
        if let outputURL {
          url = outputURL
        } else {
          let resolved = try resolveOutputURL(for: configuration, allowExplicitFile: true)
          url = resolved.url
          applyFileProtectionIfNeeded(resolved.protection, to: url)
        }

        let writer = try makeRecordingWriter(
          url: url,
          configuration: configuration,
          writerBackend: recordingLifecycleState.writerBackend,
        )

        let sampleRate = Int(processingFormat.sampleRate)
        let channelCount = Int(processingFormat.channelCount)
        guard sampleRate > 0, channelCount > 0 else {
          throw .invalidConfiguration(details: "Invalid processing format")
        }
        try lifecycle.capture.validateRecordingChannelCapacity(channelCount: channelCount)

        let audioBuffers = lifecycle.capture.makeAudioBuffers(
          sampleRate: sampleRate,
          channelCount: channelCount,
        )
        let receiverBuffers =
          enableReceivers
          ? lifecycle.capture.makeAudioBuffers(
            sampleRate: sampleRate,
            channelCount: channelCount,
          )
          : nil
        let timingCapacity = max(
          64,
          Int(ceil(Double(sampleRate) / Double(bufferSize))) * 4,
        )
        let receiverTiming =
          enableReceivers
          ? SPSCRingBuffer<TimingPacket>(capacity: timingCapacity)
          : nil

        resetRecordingTiming()

        state {
          $0.recordingWriter = writer
          $0.recordingURL = url
          $0.audioBuffers = audioBuffers
          $0.receiverBuffers = receiverBuffers
          $0.receiverTiming = receiverTiming
          $0.recordingConfiguration = configuration
          $0.installedTapBus = nil
          $0.captureBackend = TestingCaptureBackend(owner: self)
        }

        lifecycle.writer.start(flushing: audioBuffers, format: processingFormat, to: writer)
        if let receiverBuffers, let receiverTiming, enableReceivers {
          lifecycle.receiver.start(
            buffers: receiverBuffers,
            timing: receiverTiming,
            format: processingFormat,
          )
        }

        isRecording = true
        return url
      }

      /// Injects PCM samples directly into the writer/receiver buffers for tests.
      public nonisolated func injectTestAudio(
        channels: [[Float]],
        hostTime: UInt64? = nil,
        sourceSampleTime: Int64? = nil,
        sourceSampleRate: Double? = nil,
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

        let writerAvailable = RecordingLifecycle.Writer.minimumAvailableWriteFrames(
          channelCount: effectiveChannelCount,
          audioBuffers: audioBuffers,
          limit: frameLength,
        )
        let writerCanWrite = writerAvailable >= frameLength

        let receiverCanWrite: Bool =
          if let receiverBuffers, let timingBuffer {
            timingBuffer.availableToWrite >= 1
              && RecordingLifecycle.Writer.minimumAvailableWriteFrames(
                channelCount: effectiveChannelCount,
                audioBuffers: receiverBuffers,
                limit: frameLength,
              ) >= frameLength
          } else {
            false
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

        if writerCanWrite {
          recordPersistedBufferTiming(
            frameCount: frameLength,
            hostTime: hostTime,
            sourceSampleTime: sourceSampleTime,
          )
        }

        if receiverCanWrite, let timingBuffer {
          let startSampleTime = recordingSampleTimeAtomic.load(ordering: .relaxed)
          var packet = TimingPacket(
            startSampleTime: startSampleTime,
            frameCount: frameLength,
            hostTime: hostTime,
            sourceSampleTime: sourceSampleTime,
            sourceSampleRate: sourceSampleRate,
          )
          _ = unsafe withUnsafePointer(to: &packet) { pointer in
            unsafe timingBuffer.write(UnsafeBufferPointer(start: pointer, count: 1))
          }
        }

        recordingSampleTimeAtomic.wrappingIncrement(
          by: Int64(frameLength),
          ordering: .relaxed,
        )
      }

      /// Returns a closure that wraps ``processAudio(buffer:time:to:)`` for the given format.
      /// Useful for verifying the tap handler can run off the main queue.
      public nonisolated func makeTapHandlerForTesting(
        processingFormat: AVAudioFormat,
      ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [self] buffer, time in
          RecordingLifecycle(owner: self).capture.processAudio(
            buffer: buffer,
            time: time,
            to: processingFormat,
          )
        }
      }

    }

    private final class TestingRecordingFileWriter: RecordingFileWriter {
      let fileURL: URL
      private let closeCountStorage = ManagedAtomic<Int>(0)
      private let closed: AsyncContinuation<Void>

      init(fileURL: URL, closed: AsyncContinuation<Void>) {
        self.fileURL = fileURL
        self.closed = closed
      }

      func write(_ buffer: AVAudioPCMBuffer) throws {}

      func close() {
        closeCountStorage.wrappingIncrement(ordering: .relaxed)
        try? closed.yield()
      }

      func closeCount() -> Int {
        closeCountStorage.load(ordering: .relaxed)
      }
    }
  #endif
#endif
