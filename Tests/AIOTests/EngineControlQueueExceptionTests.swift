// © GoodHatsLLC

@testable import AIOEngineCore
@testable import AudioIO
import Foundation
import Synchronization
import Testing

/// The non-`Result` engine-control helpers return `T`, so a raise cannot be
/// handed back to the caller. Their contract is instead: degrade to the
/// caller's fallback, and report what raised and where.
///
/// The asynchronous half carries a hazard the synchronous half does not. Its
/// work runs inside `queue.async` under a `withCheckedContinuation`, so a raise
/// that skipped the resume would suspend the awaiting task forever. These pin
/// that it resumes.
@Suite(.timeLimit(.minutes(1)))
struct EngineControlQueueExceptionTests {
  @Test
  func `the sync helper degrades to the fallback when work raises`() {
    let engine = AIOEngine(recordingEnvironment: .live)

    let value = engine.runOnEngineControlQueue("probe", fallingBackTo: -1) { () -> Int in
      NSException(name: .genericException, reason: "graph precondition", userInfo: nil).raise()
      return 0
    }

    #expect(value == -1)
  }

  @Test
  func `the sync helper returns the work's own answer when nothing raises`() {
    let engine = AIOEngine(recordingEnvironment: .live)

    let value = engine.runOnEngineControlQueue("probe", fallingBackTo: -1) { 7 }

    #expect(value == 7)
  }

  @Test
  func `the void sync helper carries on past a raise`() {
    let engine = AIOEngine(recordingEnvironment: .live)
    var reached = false

    engine.runOnEngineControlQueue("probe") {
      NSException(name: .genericException, reason: "graph precondition", userInfo: nil).raise()
    }
    reached = true

    #expect(reached)
  }

  @Test
  func `the async helper resumes with the fallback rather than suspending`() async {
    // The regression this guards is a hang, not a wrong value: a `resume`
    // placed in the success branch alone would never run on the raising path.
    //
    // So the call is *not* awaited directly. An awaited hang would hold the
    // suite for its whole time limit and can outlive the run holding the
    // package lock; an unstructured task that never resumes is simply
    // abandoned, and the deadline below turns the hang into a fast failure.
    let engine = AIOEngine(recordingEnvironment: .live)

    let value = await settledValue { () -> Int in
      await engine.withEngineControlQueue("probe", fallingBackTo: -1) { () -> Int in
        NSException(name: .genericException, reason: "graph precondition", userInfo: nil).raise()
        return 0
      }
    }

    #expect(value == -1, "the continuation was never resumed")
  }

  @Test
  func `the void async helper resumes past a raise`() async {
    let engine = AIOEngine(recordingEnvironment: .live)

    let completed = await settledValue { () -> Bool in
      await engine.withEngineControlQueue("probe") {
        NSException(name: .genericException, reason: "graph precondition", userInfo: nil).raise()
      }
      return true
    }

    #expect(completed == true, "the continuation was never resumed")
  }

  @Test
  func `a raise is reported on the error stream, attributed to its stage`() async {
    // Attribution is the whole point of the `stage` label: the report is the
    // only place a swallowed raise is visible, so it has to name the operation.
    let engine = AIOEngine(recordingEnvironment: .live)
    let subscription = engine.events.subscribe()
    let firstError = Task {
      for await event in subscription.events {
        if case .error(let error) = event { return error.description }
      }
      return "stream ended with no error event"
    }

    _ = await settledValue { () -> Bool in
      await engine.withEngineControlQueue("recording graph teardown") {
        NSException(
          name: .genericException,
          reason: "required condition is false: fake",
          userInfo: nil,
        ).raise()
      }
      return true
    }

    let description = await firstError.value
    subscription.cancel()

    #expect(description.contains("recording graph teardown"))
    #expect(description.contains("required condition is false: fake"))
  }

  // MARK: - Helpers

  /// Runs `work` in an unstructured task and returns its value, or `nil` if it
  /// has not produced one within a short deadline.
  ///
  /// The task is deliberately not awaited. A helper that failed to resume its
  /// continuation would suspend forever, and awaiting that would hang the run
  /// rather than fail it.
  private func settledValue<T: Sendable>(
    within deadline: Duration = .seconds(2),
    _ work: @escaping @Sendable () async -> T,
  ) async -> T? {
    let box = Mutex<T?>(nil)
    let task = Task {
      let value = await work()
      box.withLock { $0 = value }
    }
    defer { task.cancel() }

    let clock = ContinuousClock()
    let end = clock.now.advanced(by: deadline)
    while clock.now < end {
      if let value = box.withLock({ $0 }) { return value }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return box.withLock { $0 }
  }
}
