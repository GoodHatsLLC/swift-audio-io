// © GoodHatsLLC

import Atomics
import Testing
import Tools

@testable import AIOAudioSession
@testable import AIOEngine

struct BufferReceiverLifecycleTests {
  @Test
  func `detach calls end buffer task and releases receiver`() async {
    let engine = AIOEngine()

    // SAFETY: Test fake. The only mutable state is `endCount`, a
    // ManagedAtomic which is thread-safe by construction. BufferReceiver
    // isn't Sendable by nature.
    final class TestReceiver: BufferReceiver, @unchecked Sendable {
      typealias T = Float
      let endCount = ManagedAtomic<Int>(0)

      nonisolated func processBuffer(_: UnsafeBufferPointer<Float>) {}
      nonisolated func processBuffer(_: UnsafeBufferPointer<Float>, timing _: BufferTiming) {}

      nonisolated func endBufferTask() {
        endCount.wrappingIncrement(by: 1, ordering: .relaxed)
      }
    }

    weak var weakReceiver: TestReceiver?
    do {
      let receiver = TestReceiver()
      weakReceiver = receiver

      await engine.attachBufferReceiver(receiver)
      #expect(engine.bufferReceivers { $0.count } == 1)

      await engine.detachBufferReceivers()
      #expect(engine.bufferReceivers { $0.count } == 0)
      #expect(receiver.endCount.load(ordering: .relaxed) == 1)
    }

    #expect(weakReceiver == nil)
  }
}
