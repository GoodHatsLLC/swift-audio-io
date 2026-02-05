#if canImport(UIKit)
  import Dispatch
  import Foundation
  import Testing

  @_spi(TESTING) import AIOEngine
  import Tools

  @Suite
  struct AIOEngineReceiverTests {
    @Test
    func testReceiverRunsOnReceiverQueue() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()
      let receiver = QueueLabelReceiver()

      await engine.attachBufferReceiver(receiver)

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      engine.injectTestAudio(channels: [ramp(count: 64)])

      let received = await waitFor(
        condition: { receiver.snapshot().isEmpty == false },
        timeout: .seconds(1)
      )
      #expect(received == true)

      let labels = receiver.snapshot()
      try #require(labels.first == "AIOEngine.receiver")

      _ = try await engine.stopRecording()
    }

    @Test
    func testReceiverOrderingUsesTimingPackets() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()
      let receiver = OrderedReceiver()

      await engine.attachBufferReceiver(receiver)

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      let first = ramp(count: 32)
      let second = ramp(count: 32).map { $0 + 1 }
      engine.injectTestAudio(channels: [first])
      engine.injectTestAudio(channels: [second])

      let received = await waitFor(
        condition: { receiver.snapshot().count >= 2 },
        timeout: .seconds(1)
      )
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
    func testSlowReceiverDoesNotBlockWriter() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()
      let receiver = SlowReceiver(delay: 0.05)

      await engine.attachBufferReceiver(receiver)

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      for _ in 0..<4 {
        engine.injectTestAudio(channels: [ramp(count: 128)])
      }

      try? await Task.sleep(for: .milliseconds(200))

      let size = try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
      #expect(size > 0)

      #if DEBUG
        let metrics = engine.debugMetricsSnapshot()
        #expect(metrics.receiverUnderruns == 0)
        #expect(metrics.receiverDrops == 0)
        #expect(metrics.writerDrops == 0)
      #endif

      _ = try await engine.stopRecording()
    }

    private func makeConfiguration() -> RecordingConfiguration {
      let input = InputConfiguration(
        sampleRate: SampleRate.common(.sr48000),
        channels: .mono
      )
      let output = OutputConfiguration(
        fileFormat: .caf,
        bitDepth: .pcmFloat32,
        quality: .high
      )
      return RecordingConfiguration(
        inputConfiguration: input,
        outputConfiguration: output,
        outputDestination: .temporary
      )
    }

    private func ramp(count: Int) -> [Float] {
      guard count > 0 else { return [] }
      return (0..<count).map { Float($0) / Float(count) }
    }

    private func waitFor(
      condition: @Sendable () -> Bool,
      timeout: Duration
    ) async -> Bool {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: timeout)
      while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
      }
      return condition()
    }
  }

  private func currentQueueLabel() -> String {
    unsafe String(validatingCString: __dispatch_queue_get_label(nil)) ?? ""
  }

  private final class QueueLabelReceiver: BufferReceiver, @unchecked Sendable {
    typealias T = Float
    private let lock = NSLock()
    private var storedLabels: [String] = []

    func snapshot() -> [String] {
      lock.lock()
      defer { lock.unlock() }
      return storedLabels
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>) {
      unsafe processBuffer(data, timing: BufferTiming(sampleTime: 0, sampleRate: 48_000))
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>, timing: BufferTiming) {
      let label = currentQueueLabel()
      lock.lock()
      storedLabels.append(label)
      lock.unlock()
    }

    nonisolated func endBufferTask() {}
  }

  private final class OrderedReceiver: BufferReceiver, @unchecked Sendable {
    typealias T = Float
    private let lock = NSLock()
    private var stored: [(values: [Float], timing: BufferTiming)] = []

    func snapshot() -> [(values: [Float], timing: BufferTiming)] {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>) {
      unsafe processBuffer(data, timing: BufferTiming(sampleTime: 0, sampleRate: 48_000))
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>, timing: BufferTiming) {
      lock.lock()
      unsafe stored.append((values: Array(data), timing: timing))
      lock.unlock()
    }

    nonisolated func endBufferTask() {}
  }

  private final class SlowReceiver: BufferReceiver, @unchecked Sendable {
    typealias T = Float
    private let delay: TimeInterval

    init(delay: TimeInterval) {
      self.delay = delay
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>) {
      unsafe processBuffer(data, timing: BufferTiming(sampleTime: 0, sampleRate: 48_000))
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>, timing: BufferTiming) {
      Thread.sleep(forTimeInterval: delay)
    }

    nonisolated func endBufferTask() {}
  }
#endif
