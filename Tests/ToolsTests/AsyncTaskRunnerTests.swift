// © GoodHatsLLC

import Testing

@testable import Tools

struct AsyncTaskRunnerTests {
  @Test
  func drainWaitsForCompletionAndClearsFinishedTasks() async {
    let runner = AsyncTaskRunner()
    let started = AsyncContinuation<Void>()
    let finish = AsyncContinuation<Void>()

    runner.run {
      try? started.yield()
      await finish()
    }

    await started()
    #expect(runner.activeCount == 1)

    try? finish.yield()
    await runner.drain()

    #expect(runner.activeCount == 0)
  }

  @Test
  func cancelAllDrainsCancellationCleanup() async {
    let runner = AsyncTaskRunner()
    let started = AsyncContinuation<Void>()
    let cleaned = AsyncContinuation<Void>()
    let cancellation = CancellationGate()

    runner.run {
      try? started.yield()
      await cancellation.wait()
      try? cleaned.yield()
    }

    await started()
    await runner.cancelAll()

    await cleaned()
    #expect(runner.activeCount == 0)
  }

  @Test
  func cancelSpecificTaskLeavesOtherTasksRunning() async {
    let runner = AsyncTaskRunner()
    let firstStarted = AsyncContinuation<Void>()
    let secondStarted = AsyncContinuation<Void>()
    let firstCleaned = AsyncContinuation<Void>()
    let firstCancellation = CancellationGate()
    let secondFinish = AsyncContinuation<Void>()

    let firstID = runner.run {
      try? firstStarted.yield()
      await firstCancellation.wait()
      try? firstCleaned.yield()
    }

    runner.run {
      try? secondStarted.yield()
      await secondFinish()
    }

    await firstStarted()
    await secondStarted()

    await runner.cancel(firstID)
    await firstCleaned()
    #expect(runner.activeCount == 1)

    try? secondFinish.yield()
    await runner.drain()
    #expect(runner.activeCount == 0)
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
