// © GoodHatsLLC

import Testing

@testable import Tools

struct OwnedWorkTests {
  @Test
  func cancelDrainsDetachedOperationCleanup() async {
    let started = AsyncContinuation<Void>()
    let cleaned = AsyncContinuation<Void>()
    let cancellation = CancellationGate()

    let task = DetachedOwnedWork {
      try? started.yield()
      await cancellation.wait()
      try? cleaned.yield()
    }

    await started()
    await task.cancel()

    await cleaned()
  }

  @Test
  @MainActor
  func mainActorOwnedTaskRunsMainActorOperation() async {
    let marker = MainActorMarker()
    let finished = AsyncContinuation<Void>()

    let task = MainActorOwnedWork {
      marker.didRun = true
      try? finished.yield()
    }

    await finished()
    await task.value

    #expect(marker.didRun)
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

@MainActor
private final class MainActorMarker {
  var didRun = false
}
