#if os(iOS)
  import Atomics
  import Testing
  import Tools

  @testable import AIOEngine

  @Suite
  struct BufferReceiverLifecycleTests {
    @Test
    func testDetachCallsEndBufferTaskAndReleasesReceiver() async {
      let engine = AIOEngine()

      final class TestReceiver: BufferReceiver, @unchecked Sendable {
        typealias T = Float
        let endCount = ManagedAtomic<Int>(0)

        nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>) {}
        nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>, timing: BufferTiming) {}

        nonisolated func endBufferTask() {
          endCount.wrappingIncrement(by: 1, ordering: .relaxed)
        }
      }

      weak var weakReceiver: TestReceiver?
      do {
        let receiver = TestReceiver()
        weakReceiver = receiver

        await engine.attachBufferReceiver(receiver)
        #expect(engine.bufferReceivers({ $0.count }) == 1)

        await engine.detachBufferReceivers()
        #expect(engine.bufferReceivers({ $0.count }) == 0)
        #expect(receiver.endCount.load(ordering: .relaxed) == 1)
      }

      #expect(weakReceiver == nil)
    }
  }
#endif
