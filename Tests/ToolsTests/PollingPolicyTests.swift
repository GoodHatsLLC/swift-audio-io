// © GoodHatsLLC

import Testing

@testable import Tools

struct PollingPolicyTests {
  @Test
  func waitForNextPollDelegatesToInjectedSleeper() async throws {
    let sleeper = ManualPollingSleeper()
    let policy = PollingPolicy(interval: .milliseconds(250), sleeper: sleeper)

    async let wait: Void = policy.waitForNextPoll()

    let duration = await sleeper.nextDuration()
    #expect(duration == .milliseconds(250))

    await sleeper.release()
    try await wait
  }

  @Test
  func zeroIntervalDoesNotSleep() async throws {
    let sleeper = ManualPollingSleeper()
    let policy = PollingPolicy(interval: .zero, sleeper: sleeper)

    try await policy.waitForNextPoll()

    #expect(await sleeper.requestedDurations.isEmpty)
  }
}

private actor ManualPollingSleeper: AsyncSleeper {
  private var durations: [Duration] = []
  private let requestedDuration = AsyncContinuation<Duration>()
  private let releaseSleep = AsyncContinuation<Void>()

  var requestedDurations: [Duration] {
    durations
  }

  func sleep(for duration: Duration) async throws {
    durations.append(duration)
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
