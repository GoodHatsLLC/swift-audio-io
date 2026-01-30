#if canImport(UIKit)
  import AVFoundation
  import Testing

  @testable import AIOEngine

  @Suite
  struct SPSCRingBufferTests {
    @Test
    func testWriteReadWrap() throws {
      let buffer = SPSCRingBuffer<Int>(capacity: 4)

      let firstWrite = [1, 2, 3]
      let written1 = firstWrite.withUnsafeBufferPointer { buffer.write($0) }
      try #require(written1 == 3)

      let read1 = read(buffer, count: 2)
      try #require(read1 == [1, 2])

      let secondWrite = [4, 5, 6]
      let written2 = secondWrite.withUnsafeBufferPointer { buffer.write($0) }
      try #require(written2 == 3)

      let read2 = read(buffer, count: 4)
      try #require(read2 == [3, 4, 5, 6])
    }

    @Test
    func testDropWhenFull() throws {
      let buffer = SPSCRingBuffer<Int>(capacity: 4)

      let write1 = [1, 2, 3, 4]
      let written1 = write1.withUnsafeBufferPointer { buffer.write($0) }
      try #require(written1 == 4)

      let write2 = [5, 6]
      let written2 = write2.withUnsafeBufferPointer { buffer.write($0) }
      try #require(written2 == 0)

      let read1 = read(buffer, count: 4)
      try #require(read1 == [1, 2, 3, 4])
    }

    @Test
    func testReceiverLoopDeliversTiming() async throws {
      let buffers = [SPSCRingBuffer<Float>(capacity: 16)]
      let timing = SPSCRingBuffer<TimingPacket>(capacity: 8)
      let control = ReceiverControl()
      let receiver = CapturingReceiver(control: control)
      let receivers: Synchronized<[any BufferReceiver<Float>]> = .init([receiver])

      let format = try #require(
        AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: 48_000,
          channels: 1,
          interleaved: false
        )
      )

      let samples: [Float] = [0, 1, 2, 3]
      _ = samples.withUnsafeBufferPointer { buffers[0].write($0) }
      var packet = TimingPacket(
        startSampleTime: 0,
        frameCount: samples.count,
        hostTime: nil,
        sourceSampleTime: nil,
        sourceSampleRate: nil
      )
      withUnsafePointer(to: &packet) { pointer in
        _ = timing.write(UnsafeBufferPointer(start: pointer, count: 1))
      }

      let task = Task.detached {
        AIOEngine.receiverLoopSync(
          buffers: buffers,
          timing: timing,
          processingFormat: format,
          bufferReceivers: receivers,
          control: control,
          cadence: .milliseconds(1),
          onUnderrun: nil,
          onDrop: nil,
          tapErrorPoll: nil,
          onTapError: nil
        )
      }

      let start = ContinuousClock.now
      while receiver.isEmpty && (ContinuousClock.now - start) < .seconds(1) {
        try? await Task.sleep(for: .milliseconds(10))
      }

      let snapshot = receiver.snapshot()
      try #require(snapshot.values == samples)
      try #require(snapshot.timing?.sampleTime == 0)

      control.cancelRequested.store(true, ordering: .relaxed)
      _ = await task.result
    }

    private func read(_ buffer: SPSCRingBuffer<Int>, count: Int) -> [Int] {
      guard count > 0 else { return [] }
      let storage = UnsafeMutablePointer<Int>.allocate(capacity: count)
      defer { storage.deallocate() }
      let read = buffer.read(into: UnsafeMutableBufferPointer(start: storage, count: count))
      guard read > 0 else { return [] }
      return Array(UnsafeBufferPointer(start: storage, count: read))
    }
  }

  private final class CapturingReceiver: BufferReceiver<Float>, @unchecked Sendable {
    private let control: ReceiverControl
    private let lock = NSLock()
    private var storedValues: [Float] = []
    private var storedTiming: BufferTiming?

    init(control: ReceiverControl) {
      self.control = control
    }

    var isEmpty: Bool {
      lock.lock()
      defer { lock.unlock() }
      return storedValues.isEmpty
    }

    func snapshot() -> (values: [Float], timing: BufferTiming?) {
      lock.lock()
      defer { lock.unlock() }
      return (storedValues, storedTiming)
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>) {
      processBuffer(data, timing: BufferTiming(sampleTime: 0, sampleRate: 48_000))
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>, timing: BufferTiming) {
      lock.lock()
      storedValues = Array(data)
      storedTiming = timing
      lock.unlock()
      control.cancelRequested.store(true, ordering: .relaxed)
    }

    nonisolated func endBufferTask() {}
  }
#endif
