// © GoodHatsLLC

import Testing

@testable import Tools

struct DebouncePolicyTests {
  @Test
  func waitDelegatesToInjectedSleeper() async throws {
    let sleeper = ManualSleeper()
    let policy = DebouncePolicy(delay: .milliseconds(300), sleeper: sleeper)

    async let wait: Void = policy.wait()

    let duration = await sleeper.nextDuration()
    #expect(duration == .milliseconds(300))

    await sleeper.release()
    try await wait
  }
}

private actor ManualSleeper: AsyncSleeper {
  private let requestedDuration = AsyncContinuation<Duration>()
  private let releaseSleep = AsyncContinuation<Void>()

  func sleep(for duration: Duration) async throws {
    try requestedDuration.yield(duration)
    await releaseSleep()
  }

  func nextDuration() async -> Duration {
    await requestedDuration()
  }

  func release() {
    try? releaseSleep.yield()
  }
}
