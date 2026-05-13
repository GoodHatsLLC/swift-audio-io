// © GoodHatsLLC

import Testing

@testable import Tools

struct ContinuationTests {
  @Test
  func `yields to awaiters registered before yield`() async throws {
    let continuation = AsyncContinuation<Int>()
    let firstReady = AsyncContinuation<Void>()
    let secondReady = AsyncContinuation<Void>()

    let first = ActorOwnedWork {
      try? firstReady.yield()
      return await continuation()
    }
    let second = ActorOwnedWork {
      try? secondReady.yield()
      return await continuation()
    }
    await firstReady()
    await secondReady()

    try continuation.yield(42)

    #expect(await first.value == 42)
    #expect(await second.value == 42)
  }

  @Test
  func `returns yielded value for future waiters`() async throws {
    let continuation = AsyncContinuation<Int>()
    try continuation.yield(7)

    #expect(await continuation() == 7)
    #expect(await continuation() == 7)
  }

  @Test
  func `throws already yielded with original value metadata`() throws {
    let continuation = AsyncContinuation<Int>()
    try continuation.yield(1)

    do {
      try continuation.yield(2)
      Issue.record("Expected the second yield to throw.")
    } catch {
      #expect(error.id == continuation.id)
      #expect(error.yieldedValueDescription == "1")
      #expect(error.description.contains("already yielded"))
    }
  }

  @Test
  func `result wraps value in success`() async throws {
    let continuation = AsyncContinuation<String>()
    try continuation.yield("ok")

    #expect(await continuation.result == .success("ok"))
  }

  @Test
  func `void convenience yield resumes waiters`() async throws {
    let continuation = AsyncContinuation<Void>()
    let waiterReady = AsyncContinuation<Void>()

    let waiter = ActorOwnedWork {
      try? waiterReady.yield()
      await continuation()
    }
    await waiterReady()
    try continuation.yield()

    await waiter.value
  }
}
