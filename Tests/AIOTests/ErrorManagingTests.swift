import Foundation
import Testing

@testable import AIOEngine

@Suite
struct ErrorManagingTests {
  struct TestError: LocalizedError {
    var errorDescription: String? { "test error" }
  }

  @Test
  @MainActor
  func mockErrorManagerStoresEvents() {
    let manager = MockErrorManager()
    manager.enqueue(TestError(), visibility: .debug, context: "test")

    let event = manager.popEvent()
    #expect(event?.localizedDescription == "test error")
  }

  @Test
  @MainActor
  func anyErrorManagerForwardsToBase() {
    let base = MockErrorManager()
    let erased = AnyErrorManager(base)

    erased.enqueue(TestError(), visibility: .userInterrupting, context: "forward")

    let event = base.popEvent()
    #expect(event?.context == "forward")
  }
}
