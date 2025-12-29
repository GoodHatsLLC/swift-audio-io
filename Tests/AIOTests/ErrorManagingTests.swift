import Testing

@testable import AIOEngine

@Suite
struct ErrorManagingTests {
  struct TestError: LocalizedError {
    var errorDescription: String? { "test error" }
  }

  @Test
  func mockErrorManagerStoresEvents() async {
#if DEBUG
    let manager = MockErrorManager()
    await MainActor.run {
      manager.enqueue(TestError(), visibility: .debug, context: "test")
    }

    let event = await MainActor.run { manager.popEvent() }
    #expect(event?.localizedDescription == "test error")
#else
    #expect(true)
#endif
  }

  @Test
  func anyErrorManagerForwardsToBase() async {
#if DEBUG
    let base = MockErrorManager()
    let erased = AnyErrorManager(base)

    await MainActor.run {
      erased.enqueue(TestError(), visibility: .userInterrupting, context: "forward")
    }

    let event = await MainActor.run { base.popEvent() }
    #expect(event?.context == "forward")
#else
    #expect(true)
#endif
  }
}

