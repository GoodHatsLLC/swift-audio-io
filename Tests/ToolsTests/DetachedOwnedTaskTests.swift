// © GoodHatsLLC

import Testing

@testable import Tools

struct DetachedOwnedTaskTests {
  @Test
  func cancelDrainsDetachedOperationCleanup() async {
    let started = AsyncContinuation<Void>()
    let cleaned = AsyncContinuation<Void>()
    let cancellation = CancellationGate()

    let task = DetachedOwnedTask {
      try? started.yield()
      await cancellation.wait()
      try? cleaned.yield()
    }

    await started()
    await task.cancel()

    await cleaned()
  }
}

private final class CancellationGate: Sendable {
  private let continuation = AsyncContinuation<Void>()

  func wait() async {
    await withTaskCancellationHandler {
      await continuation()
    } onCancel: {
      try? continuation.yield()
    }
  }
}
