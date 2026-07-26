// © GoodHatsLLC

#if canImport(AVFoundation)
  import Atomics
  import AVFoundation
  import Testing
  import Tools
  @testable import AIOAudioSession
  @testable import AudioIO
  @testable import AIORecording
  @testable import AIORecordingSupport

  struct SPSCRingBufferTests {
    @Test
    func `write read wrap`() throws {
      let buffer = SPSCRingBuffer<Int>(capacity: 4)

      let firstWrite = [1, 2, 3]
      let written1 = unsafe firstWrite.withUnsafeBufferPointer { unsafe buffer.write($0) }
      try #require(written1 == 3)

      let read1 = read(buffer, count: 2)
      try #require(read1 == [1, 2])

      let secondWrite = [4, 5, 6]
      let written2 = unsafe secondWrite.withUnsafeBufferPointer { unsafe buffer.write($0) }
      try #require(written2 == 3)

      let read2 = read(buffer, count: 4)
      try #require(read2 == [3, 4, 5, 6])
    }

    @Test
    func `drop when full`() throws {
      let buffer = SPSCRingBuffer<Int>(capacity: 4)

      let write1 = [1, 2, 3, 4]
      let written1 = unsafe write1.withUnsafeBufferPointer { unsafe buffer.write($0) }
      try #require(written1 == 4)

      let write2 = [5, 6]
      let written2 = unsafe write2.withUnsafeBufferPointer { unsafe buffer.write($0) }
      try #require(written2 == 0)

      let read1 = read(buffer, count: 4)
      try #require(read1 == [1, 2, 3, 4])
    }

    @Test
    func `receiver loop delivers timing`() async throws {
      let buffers = [SPSCRingBuffer<Float>(capacity: 16)]
      let timing = SPSCRingBuffer<TimingPacket>(capacity: 8)
      let control = ReceiverControl()
      let receiver = CapturingReceiver(control: control)
      let receivers: Synchronized<[any BufferReceiver<Float>]> = .init([receiver])

      let format = try #require(
        AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: 48000,
          channels: 1,
          interleaved: false,
        ),
      )

      let samples: [Float] = [0, 1, 2, 3]
      _ = unsafe samples.withUnsafeBufferPointer { unsafe buffers[0].write($0) }
      var packet = TimingPacket(
        startSampleTime: 0,
        frameCount: samples.count,
        hostTime: nil,
        sourceSampleTime: nil,
        sourceSampleRate: nil,
      )
      unsafe withUnsafePointer(to: &packet) { pointer in
        _ = unsafe timing.write(UnsafeBufferPointer(start: pointer, count: 1))
      }

      let work = ActorOwnedWork {
        RecordingLifecycle.Receiver.runLoop(
          buffers: buffers,
          timing: timing,
          processingFormat: format,
          bufferReceivers: receivers,
          control: control,
          cadence: .milliseconds(1),
          onUnderrun: nil,
          onDrop: nil,
          tapErrorPoll: nil,
          onTapError: nil,
        )
      }

      await receiver.received()

      let snapshot = receiver.snapshot()
      try #require(snapshot.values == samples)
      try #require(snapshot.timing?.sampleTime == 0)

      control.cancelRequested.store(true, ordering: .relaxed)
      await work.value
    }

    private func read(_ buffer: SPSCRingBuffer<Int>, count: Int) -> [Int] {
      guard count > 0 else { return [] }
      let storage = UnsafeMutablePointer<Int>.allocate(capacity: count)
      defer { unsafe storage.deallocate() }
      let read = unsafe buffer.read(into: UnsafeMutableBufferPointer(start: storage, count: count))
      guard read > 0 else { return [] }
      return unsafe Array(UnsafeBufferPointer(start: storage, count: read))
    }
  }

  // SAFETY: Test fake. All mutation of `storedValues` and `storedTiming` is
  // guarded by the NSLock `lock`. `control` is a let. BufferReceiver isn't
  // Sendable by nature.
  private final class CapturingReceiver: BufferReceiver, @unchecked Sendable {
    typealias T = Float
    private let control: ReceiverControl
    private let receivedSignal = AsyncContinuation<Void>()
    private let lock = NSLock()
    private var storedValues: [Float] = []
    private var storedTiming: BufferTiming?

    init(control: ReceiverControl) {
      self.control = control
    }

    func received() async {
      await receivedSignal()
    }

    func snapshot() -> (values: [Float], timing: BufferTiming?) {
      lock.lock()
      defer { lock.unlock() }
      return (storedValues, storedTiming)
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>) {
      unsafe processBuffer(data, timing: BufferTiming(sampleTime: 0, sampleRate: 48000))
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>, timing: BufferTiming) {
      lock.lock()
      storedValues = unsafe Array(data)
      storedTiming = timing
      lock.unlock()
      try? receivedSignal.yield()
      control.cancelRequested.store(true, ordering: .relaxed)
    }

    nonisolated func endBufferTask() {}
  }
#endif
