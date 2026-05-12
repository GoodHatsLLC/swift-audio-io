// © GoodHatsLLC

import Testing

@testable import Tools

struct ReplacingTaskSlotTests {
  @Test
  func cancelDrainsOperationCleanup() async {
    let slot = ReplacingTaskSlot()
    let started = AsyncContinuation<Void>()
    let cleaned = AsyncContinuation<Void>()
    let cancellation = CancellationGate()

    await slot.replace {
      try? started.yield()
      await cancellation.wait()
      try? cleaned.yield()
    }

    await started()
    await slot.cancel()

    await cleaned()
    #expect(await slot.isActive == false)
  }

  @Test
  func replaceDrainsPreviousTaskBeforeStartingNextTask() async {
    let slot = ReplacingTaskSlot()
    let events = EventLog()
    let firstStarted = AsyncContinuation<Void>()
    let firstCleaned = AsyncContinuation<Void>()
    let cancellation = CancellationGate()

    await slot.replace {
      await events.append("first-started")
      try? firstStarted.yield()
      await cancellation.wait()
      await events.append("first-cleaned")
      try? firstCleaned.yield()
    }

    await firstStarted()

    async let replacement: Void = slot.replace {
      await events.append("second-started")
    }

    await firstCleaned()
    await replacement

    #expect(await events.values == ["first-started", "first-cleaned", "second-started"])
  }

  @Test
  func completedTaskClearsActiveState() async {
    let slot = ReplacingTaskSlot()
    let finished = AsyncContinuation<Void>()

    await slot.replace {
      try? finished.yield()
    }

    await finished()
    await slot.waitForCurrentTask()

    #expect(await slot.isActive == false)
  }

  @Test
  func cancelIsIdempotentWhenSlotIsEmpty() async {
    let slot = ReplacingTaskSlot()

    await slot.cancel()
    await slot.cancel()

    #expect(await slot.isActive == false)
  }
}

private actor EventLog {
  private var storage: [String] = []

  var values: [String] {
    storage
  }

  func append(_ value: String) {
    storage.append(value)
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
