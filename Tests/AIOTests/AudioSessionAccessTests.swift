// © GoodHatsLLC

import Dispatch
import Testing
@testable import AIOSupport

private enum AudioSessionAccessTestError: Error, Sendable, Equatable {
  case expected
}

@Suite("AudioSessionAccess")
struct AudioSessionAccessTests {
  @MainActor
  @Test("async result executes away from the main queue")
  func asyncResultExecutesOffMain() async throws {
    let result = await AudioSessionAccess.result(catching: AudioSessionAccessTestError.self) {
      () throws(AudioSessionAccessTestError) -> Bool in
      dispatchPrecondition(condition: .notOnQueue(.main))
      return true
    }

    #expect(try result.get())
  }

  @Test("async result preserves typed failures")
  func asyncResultPreservesTypedFailure() async {
    let result = await AudioSessionAccess.result(catching: AudioSessionAccessTestError.self) {
      () throws(AudioSessionAccessTestError) -> Void in
      throw .expected
    }

    switch result {
    case .success:
      Issue.record("Expected typed failure")
    case .failure(let error):
      #expect(error == .expected)
    }
  }
}
