// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOEngineCore
  import Atomics
  package import AVFoundation
  import Foundation
  package import Tools

  /// Read-only views into engine internals that assertions need but the public
  /// interface does not expose.
  ///
  /// These are observation only — nothing here changes engine behaviour. They
  /// live in the test-support target rather than the shipping engine so the
  /// production interface stays the interface consumers see.
  extension AIOEngine {
    package struct MetricsSnapshot: Sendable {
      package let tapCallbackCount: Int64
      package let tapCallbackMaxNanos: UInt64
      package let writerUnderruns: Int64
      package let writerStallCount: Int64
      package let receiverUnderruns: Int64
      package let writerDrops: Int64
      package let receiverDrops: Int64
    }

    package nonisolated func metricsSnapshot() -> MetricsSnapshot {
      MetricsSnapshot(
        tapCallbackCount: metrics.tapCallbackCount.load(ordering: .relaxed),
        tapCallbackMaxNanos: metrics.tapCallbackMaxNanos.load(ordering: .relaxed),
        writerUnderruns: metrics.writerUnderruns.load(ordering: .relaxed),
        writerStallCount: metrics.writerStallCount.load(ordering: .relaxed),
        receiverUnderruns: metrics.receiverUnderruns.load(ordering: .relaxed),
        writerDrops: metrics.writerDrops.load(ordering: .relaxed),
        receiverDrops: metrics.receiverDrops.load(ordering: .relaxed),
      )
    }

    package nonisolated func bufferCapacities() -> (writer: [Int], receiver: [Int]) {
      let (writerBuffers, receiverBuffers) = state.withLock { state in
        (state.audioBuffers, state.receiverBuffers)
      }
      return (
        writer: writerBuffers?.map(\.capacity) ?? [],
        receiver: receiverBuffers?.map(\.capacity) ?? [],
      )
    }

    @MainActor
    package func currentWriterWrittenSampleTime() -> Int64 {
      recordingLifecycleState.writerSession?.control.writtenSampleTime.load(
        ordering: .relaxed,
      ) ?? 0
    }

    @MainActor
    package func currentRecordingURL() -> URL? {
      state[locked: \.recordingURL]
    }

    @MainActor
    package func installedTapBus() -> Int? {
      state[locked: \.installedTapBus]
    }

    @MainActor
    package func drainingWriterSessionIDs() -> [UUID] {
      recordingLifecycleState.drainingWriterSessions.map(\.id)
    }

    package nonisolated func drainRecordingCallbacks() async {
      await recordingCallbackTasks.drain()
    }

    /// Forces the engine-teardown serialization sentinel, simulating a teardown
    /// that raised the flag before its on-queue work cleared state. Drives the
    /// on-queue reinstall guard without racing a real `gracefulStop()`.
    @MainActor
    package func setEngineTearingDown(_ value: Bool) {
      engineTearingDown.store(value, ordering: .sequentiallyConsistent)
    }

    /// Returns a closure wrapping the real tap callback, for verifying it can
    /// run off the main queue.
    package nonisolated func makeTapHandler(
      processingFormat: AVAudioFormat,
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
      { [self] buffer, time in
        self.recording.capture.processAudio(
          buffer: buffer,
          time: time,
          to: processingFormat,
        )
      }
    }
  }

  // MARK: - Queued writer drain

  extension AIOEngine {
    package struct WriterDrainTestHandle: Sendable {
      package let id: UUID
      package let fileURL: URL
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

      package var stopRequested: Bool { control.stopRequested.load(ordering: .relaxed) }
      package var targetSampleTime: Int64 { control.targetSampleTime.load(ordering: .relaxed) }
      package var writtenSampleTime: Int64 { control.writtenSampleTime.load(ordering: .relaxed) }

      package func closeCount() -> Int { closeCountValue() }
      package func signalDrain() async { await control.drainSignal.signal() }
      package func waitUntilClosed() async { await closed() }
    }

    @MainActor
    package func startQueuedWriterDrain(
      fileURL: URL,
      targetSampleTime: Int64 = 1,
      writtenSampleTime: Int64 = 0,
    ) -> WriterDrainTestHandle {
      recordingSampleTimeAtomic.store(targetSampleTime, ordering: .relaxed)
      let control = WriterControl()
      let closed = AsyncContinuation<Void>()
      control.writtenSampleTime.store(writtenSampleTime, ordering: .relaxed)
      let writer = FakeRecordingFileWriter(fileURL: fileURL, closed: closed)
      let session = WriterSession(
        id: UUID(),
        control: control,
        writer: writer,
        fileURL: fileURL,
        // A first-file session: its frame domain is the capture's own, so the
        // explicit `writtenSampleTime` above needs no offset.
        startFramePosition: 0,
      )
      self.recording.writer.enqueueDrain(for: session)
      return WriterDrainTestHandle(
        id: session.id,
        fileURL: fileURL,
        control: control,
        closeCountValue: { writer.closeCount() },
        closed: closed,
      )
    }
  }

  /// A writer that counts closes instead of touching the filesystem.
  package final class FakeRecordingFileWriter: RecordingFileWriter {
    package let fileURL: URL
    private let closeCountStorage = ManagedAtomic<Int>(0)
    private let closed: AsyncContinuation<Void>

    package init(fileURL: URL, closed: AsyncContinuation<Void>) {
      self.fileURL = fileURL
      self.closed = closed
    }

    package func write(_ buffer: AVAudioPCMBuffer) throws {}

    package func close() {
      closeCountStorage.wrappingIncrement(ordering: .relaxed)
      try? closed.yield()
    }

    package func closeCount() -> Int {
      closeCountStorage.load(ordering: .relaxed)
    }
  }
#endif
