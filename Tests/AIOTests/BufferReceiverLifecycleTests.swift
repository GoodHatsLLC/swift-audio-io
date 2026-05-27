// © GoodHatsLLC

import Atomics
import Testing
import Tools

@testable import AIOAudioSession
@testable import AudioIO

struct BufferReceiverLifecycleTests {
  @Test
  func `detach calls end buffer task and releases receiver`() async {
    let engine = AIOEngine()

    weak var weakReceiver: TestReceiver?
    do {
      let receiver = TestReceiver()
      weakReceiver = receiver

      let token = await engine.attachBufferReceiver(receiver)
      #expect(engine.bufferReceivers { $0.count } == 1)

      await engine.detachBufferReceivers()
      #expect(engine.bufferReceivers { $0.count } == 0)
      #expect(receiver.endCount.load(ordering: .relaxed) == 1)
      token.invalidate()
      #expect(receiver.endCount.load(ordering: .relaxed) == 1)
    }

    #expect(weakReceiver == nil)
  }

  @Test
  func `token invalidation detaches only matching receiver`() async {
    let engine = AIOEngine()
    let first = TestReceiver()
    let second = TestReceiver()

    let firstToken = await engine.attachBufferReceiver(first)
    let secondToken = await engine.attachBufferReceiver(second)
    #expect(engine.bufferReceivers { $0.count } == 2)

    firstToken.invalidate()
    #expect(engine.bufferReceivers { $0.count } == 1)
    #expect(first.endCount.load(ordering: .relaxed) == 1)
    #expect(second.endCount.load(ordering: .relaxed) == 0)

    secondToken.invalidate()
    #expect(engine.bufferReceivers { $0.count } == 0)
    #expect(second.endCount.load(ordering: .relaxed) == 1)
  }

  @Test
  func `receiver can reattach after token invalidation`() async {
    let engine = AIOEngine()
    let receiver = TestReceiver()

    let firstToken = await engine.attachBufferReceiver(receiver)
    firstToken.invalidate()
    #expect(engine.bufferReceivers { $0.count } == 0)

    let secondToken = await engine.attachBufferReceiver(receiver)
    #expect(engine.bufferReceivers { $0.count } == 1)

    secondToken.invalidate()
    #expect(engine.bufferReceivers { $0.count } == 0)
    #expect(receiver.endCount.load(ordering: .relaxed) == 2)
  }

  @Test
  func `dropping token detaches receiver and releases it`() async {
    let engine = AIOEngine()
    weak var weakReceiver: TestReceiver?

    do {
      let receiver = TestReceiver()
      weakReceiver = receiver
      var token: BufferReceiverToken? = await engine.attachBufferReceiver(receiver)
      #expect(engine.bufferReceivers { $0.count } == 1)
      #expect(token != nil)

      token = nil
      #expect(engine.bufferReceivers { $0.count } == 0)
      #expect(receiver.endCount.load(ordering: .relaxed) == 1)
    }

    #expect(weakReceiver == nil)
  }

  // SAFETY: Test fake mutable state is limited to the thread-safe `ManagedAtomic` end count.
  private final class TestReceiver: BufferReceiver, @unchecked Sendable {
    typealias T = Float
    let endCount = ManagedAtomic<Int>(0)

    nonisolated func processBuffer(_: UnsafeBufferPointer<Float>) {}
    nonisolated func processBuffer(_: UnsafeBufferPointer<Float>, timing _: BufferTiming) {}

    nonisolated func endBufferTask() {
      endCount.wrappingIncrement(by: 1, ordering: .relaxed)
    }
  }
}
