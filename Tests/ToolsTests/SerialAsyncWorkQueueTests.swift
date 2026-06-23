// © GoodHatsLLC

import Dispatch
import Testing

@testable import Tools

struct SerialAsyncWorkQueueTests {
  /// Jobs must run strictly one at a time: no two job bodies may be active
  /// concurrently even when many are enqueued back-to-back.
  @Test
  func jobsNeverOverlap() async {
    let queue = SerialAsyncWorkQueue()
    let monitor = OverlapMonitor()
    let done = Counter()

    for _ in 0..<50 {
      queue.enqueue {
        await monitor.enter()
        // Yield to give any (incorrectly) concurrent job a chance to overlap.
        await Task.yield()
        await monitor.leave()
        await done.increment()
      }
    }

    await done.waitFor(50)
    #expect(await monitor.maxConcurrent == 1)
    #expect(await monitor.sawConcurrency == false)
  }

  /// Fire-and-forget `enqueue` and awaited `submit` share one FIFO order, so an
  /// `enqueue` issued first is guaranteed to have run before a later `submit`
  /// returns.
  @Test
  func enqueueAndSubmitShareFifoOrder() async {
    let queue = SerialAsyncWorkQueue()
    let log = EventLog()

    queue.enqueue { await log.append("a") }
    queue.enqueue { await log.append("b") }
    await queue.submit { await log.append("c") }

    // By the time the awaited `submit` returns, all three have run in order.
    #expect(await log.values == ["a", "b", "c"])
  }

  /// The returning `submit` yields the job's value, in order behind earlier work.
  @Test
  func submitReturnsValueAfterPriorWork() async {
    let queue = SerialAsyncWorkQueue()
    let log = EventLog()

    queue.enqueue { await log.append("first") }
    let value: Int? = await queue.submit { () async -> Int in
      await log.append("second")
      return 42
    }

    #expect(value == 42)
    #expect(await log.values == ["first", "second"])
  }

  /// Submitting to an already-finished queue must not run the job and must not
  /// hang — it returns immediately.
  @Test
  func submitAfterFinishReturnsWithoutRunning() async {
    let queue = SerialAsyncWorkQueue()
    queue.finish()

    let ran = Flag()
    await queue.submit { await ran.set() }
    #expect(await ran.value == false)

    let value: Int? = await queue.submit { 7 }
    #expect(value == nil)
  }

  /// Jobs already buffered when `finish()` is called still run to completion —
  /// `finish()` ends the stream but does not cancel the consumer or drop the
  /// buffer. Both jobs are enqueued synchronously (so provably buffered) before
  /// `finish()`; a gate holds the consumer on the first until after `finish()`.
  @Test
  func bufferedJobsRunAfterFinish() async {
    let queue = SerialAsyncWorkQueue()
    let log = EventLog()
    let gate = AsyncContinuation<Void>()

    queue.enqueue {
      await gate()
      await log.append("gate")
    }
    queue.enqueue { await log.append("buffered") }
    queue.finish()
    try? gate.yield()

    await log.waitFor(2)
    #expect(await log.values == ["gate", "buffered"])
  }

  /// Awaited jobs run off the main actor (the consumer is detached), even when
  /// the queue is created and driven from `@MainActor`. Pins the SE-0461
  /// contract for this primitive.
  @MainActor
  @Test
  func jobsRunOffTheMainActor() async {
    let queue = SerialAsyncWorkQueue()
    await queue.submit {
      dispatchPrecondition(condition: .notOnQueue(.main))
    }
  }
}

private actor OverlapMonitor {
  private var current = 0
  private(set) var maxConcurrent = 0
  private(set) var sawConcurrency = false

  func enter() {
    current += 1
    maxConcurrent = max(maxConcurrent, current)
    if current > 1 { sawConcurrency = true }
  }

  func leave() {
    current -= 1
  }
}

private actor Counter {
  private var count = 0

  func increment() {
    count += 1
  }

  func waitFor(_ target: Int) async {
    while count < target {
      await Task.yield()
    }
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

  func waitFor(_ target: Int) async {
    while storage.count < target {
      await Task.yield()
    }
  }
}

private actor Flag {
  private(set) var value = false

  func set() {
    value = true
  }
}
