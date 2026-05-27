// © GoodHatsLLC

#if canImport(UIKit)
  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #endif
  import Dispatch
  import Foundation
  import Testing

  @testable import AIOAudioSession
  @_spi(TESTING) import AudioIO
  import Tools

  struct AIOEngineReceiverTests {
    @Test
    func `receiver runs on receiver queue`() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()
      let receiver = QueueLabelReceiver()

      let receiverToken = await engine.attachBufferReceiver(receiver)
      defer { receiverToken.invalidate() }

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      engine.injectTestAudio(channels: [ramp(count: 64)])

      let received = await receiver.waitUntilReceived()
      #expect(received == true)

      let labels = receiver.snapshot()
      try #require(labels.first == "AIOEngine.receiver")

      _ = try await engine.stopRecording()
    }

    @Test
    func `receiver ordering uses timing packets`() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()
      let receiver = OrderedReceiver()

      let receiverToken = await engine.attachBufferReceiver(receiver)
      defer { receiverToken.invalidate() }

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      let first = ramp(count: 32)
      let second = ramp(count: 32).map { $0 + 1 }
      engine.injectTestAudio(channels: [first])
      engine.injectTestAudio(channels: [second])

      let received = await receiver.waitUntilReceived(count: 2)
      #expect(received == true)

      let packets = receiver.snapshot()
      try #require(packets.count >= 2)
      #expect(packets[0].timing.sampleTime == 0)
      #expect(packets[1].timing.sampleTime == Int64(first.count))
      #expect(packets[0].values == first)
      #expect(packets[1].values == second)

      _ = try await engine.stopRecording()
    }

    @Test
    func `slow receiver does not block writer`() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()
      let receiver = SlowReceiver(delay: 0.05)

      let receiverToken = await engine.attachBufferReceiver(receiver)
      defer { receiverToken.invalidate() }

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      for _ in 0..<4 {
        engine.injectTestAudio(channels: [ramp(count: 128)])
      }

      _ = try await engine.stopRecording()
      let size = try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
      #expect(size > 0)

      #if DEBUG
        let metrics = engine.debugMetricsSnapshot()
        #expect(metrics.receiverUnderruns == 0)
        #expect(metrics.receiverDrops == 0)
        #expect(metrics.writerDrops == 0)
      #endif
    }

    private func makeConfiguration() -> RecordingConfiguration {
      let input = InputConfiguration(
        sampleRate: .dvd,
        channels: .mono,
      )
      let output = OutputConfiguration(
        fileFormat: .caf,
        bitDepth: .pcmFloat32,
        quality: .high,
      )
      return RecordingConfiguration(
        inputConfiguration: input,
        outputConfiguration: output,
        outputDestination: .temporary,
      )
    }

    private func ramp(count: Int) -> [Float] {
      guard count > 0 else { return [] }
      return (0..<count).map { Float($0) / Float(count) }
    }

  }

  private func currentQueueLabel() -> String {
    unsafe String(validatingCString: __dispatch_queue_get_label(nil)) ?? ""
  }

  // SAFETY: Test fake. All mutation of `storedLabels` is guarded by the
  // NSLock `lock`. BufferReceiver isn't Sendable by nature, so @unchecked is
  // needed even though the internal state is locked.
  private final class QueueLabelReceiver: BufferReceiver, @unchecked Sendable {
    typealias T = Float
    private let lock = NSLock()
    private let received = AsyncContinuation<Void>()
    private var storedLabels: [String] = []

    func snapshot() -> [String] {
      lock.lock()
      defer { lock.unlock() }
      return storedLabels
    }

    func waitUntilReceived() async -> Bool {
      if !snapshot().isEmpty {
        return true
      }
      await received()
      return !snapshot().isEmpty
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>) {
      unsafe processBuffer(data, timing: BufferTiming(sampleTime: 0, sampleRate: 48000))
    }

    nonisolated func processBuffer(_: UnsafeBufferPointer<Float>, timing _: BufferTiming) {
      let label = currentQueueLabel()
      lock.lock()
      storedLabels.append(label)
      lock.unlock()
      try? received.yield()
    }

    nonisolated func endBufferTask() {}
  }

  // SAFETY: Test fake. All mutation of `stored` is guarded by the NSLock
  // `lock`. BufferReceiver isn't Sendable by nature.
  private final class OrderedReceiver: BufferReceiver, @unchecked Sendable {
    typealias T = Float
    private let lock = NSLock()
    private let receivedTarget = AsyncContinuation<Void>()
    private var stored: [(values: [Float], timing: BufferTiming)] = []

    func snapshot() -> [(values: [Float], timing: BufferTiming)] {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }

    func waitUntilReceived(count targetCount: Int) async -> Bool {
      if snapshot().count >= targetCount {
        return true
      }
      await receivedTarget()
      return snapshot().count >= targetCount
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>) {
      unsafe processBuffer(data, timing: BufferTiming(sampleTime: 0, sampleRate: 48000))
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>, timing: BufferTiming) {
      lock.lock()
      unsafe stored.append((values: Array(data), timing: timing))
      let count = stored.count
      lock.unlock()
      if count >= 2 {
        try? receivedTarget.yield()
      }
    }

    nonisolated func endBufferTask() {}
  }

  // SAFETY: Test fake. Only stored state is an immutable `let delay`;
  // there is no mutable state to race on. @unchecked is required only
  // because BufferReceiver isn't a Sendable protocol.
  private final class SlowReceiver: BufferReceiver, @unchecked Sendable {
    typealias T = Float
    private let delay: TimeInterval

    init(delay: TimeInterval) {
      self.delay = delay
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>) {
      unsafe processBuffer(data, timing: BufferTiming(sampleTime: 0, sampleRate: 48000))
    }

    nonisolated func processBuffer(_: UnsafeBufferPointer<Float>, timing _: BufferTiming) {
      blockReceiverQueueForBackpressureProbe(seconds: delay)
    }

    nonisolated func endBufferTask() {}

    private func blockReceiverQueueForBackpressureProbe(seconds: TimeInterval) {
      // Intentionally blocks the receiver queue to verify writer backpressure isolation.
      var requested = timespec(
        tv_sec: Int(seconds),
        tv_nsec: Int((seconds.truncatingRemainder(dividingBy: 1)) * 1_000_000_000),
      )
      var remaining = timespec()
      while unsafe nanosleep(&requested, &remaining) == -1 {
        requested = remaining
        remaining = timespec()
      }
    }
  }
#endif
