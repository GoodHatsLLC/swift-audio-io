// © GoodHatsLLC

import Testing

@testable import Tools

struct ContinuationTests {
  @Test
  func `yields to awaiters registered before yield`() async throws {
    let continuation = AsyncContinuation<Int>()

    async let first: Int = continuation()
    async let second: Int = continuation()
    await Task.yield()
    await Task.yield()

    try continuation.yield(42)

    #expect(await first == 42)
    #expect(await second == 42)
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

    async let waiter: Void = continuation()
    await Task.yield()
    try continuation.yield()

    await waiter
  }
}
