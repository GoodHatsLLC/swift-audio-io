// © GoodHatsLLC

import Foundation
import Testing

@testable import AIOAudioSession
@testable import AIOMicHealth

#if canImport(AVFAudio) && os(iOS)
  import AVFAudio
#endif

// MARK: - TestClock

// SAFETY: Test-only manual `Clock`. Mutable `elapsed` is guarded by `NSLock`
// on every read/write, so concurrent access from the monitor actor and the
// test's own isolation domain is safe. `minimumResolution` is a constant.
private final class TestClock: Clock, @unchecked Sendable {
  struct Instant: InstantProtocol {
    var durationSinceOrigin: Duration

    func advanced(by duration: Duration) -> Instant {
      Instant(durationSinceOrigin: durationSinceOrigin + duration)
    }

    func duration(to other: Instant) -> Duration {
      other.durationSinceOrigin - durationSinceOrigin
    }

    static func < (lhs: Instant, rhs: Instant) -> Bool {
      lhs.durationSinceOrigin < rhs.durationSinceOrigin
    }
  }

  private let lock = NSLock()
  private var elapsed: Duration = .zero

  var now: Instant {
    lock.lock()
    defer { lock.unlock() }
    return Instant(durationSinceOrigin: elapsed)
  }

  var minimumResolution: Duration { .nanoseconds(1) }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    // The monitor never calls `sleep`, so this is a no-op for tests.
    _ = deadline
    _ = tolerance
  }

  func advance(by duration: Duration) {
    lock.lock()
    defer { lock.unlock() }
    elapsed = elapsed + duration
  }
}

// MARK: - Harness

/// Bundle of test artefacts for driving a `MicHealthMonitor`.
private struct MonitorHarness: ~Copyable {
  let clock: TestClock
  let rmsContinuation: AsyncStream<Float>.Continuation
  let routeContinuation: AsyncStream<AudioRouteChangeEvent>.Continuation
  let monitor: MicHealthMonitor
  let runTask: Task<Void, Never>

  consuming func teardown() async {
    rmsContinuation.finish()
    routeContinuation.finish()
    runTask.cancel()
    await runTask.value
  }
}

private func makeMonitor(
  thresholds: MicHealthThresholds = .testFast,
) -> MonitorHarness {
  let clock = TestClock()
  let (rmsStream, rmsCont) = AsyncStream<Float>.makeStream()
  let (routeStream, routeCont) = AsyncStream<AudioRouteChangeEvent>.makeStream()
  let inputs = MicHealthInputs(
    rms: rmsStream,
    routeEvents: routeStream,
    clock: clock,
    thresholds: thresholds,
  )
  let monitor = MicHealthMonitor(inputs: inputs)
  let runTask = Task { await monitor.run() }
  return MonitorHarness(
    clock: clock,
    rmsContinuation: rmsCont,
    routeContinuation: routeCont,
    monitor: monitor,
    runTask: runTask,
  )
}

/// Yields several times to give the monitor actor a chance to drain its
/// input stream and apply any resulting state transitions.
private func drain() async {
  for _ in 0..<6 {
    await Task.yield()
  }
}

/// Waits briefly for a task to complete without hanging the test if the
/// expected shutdown behavior regresses.
private func waitForCompletion(
  _ task: Task<Void, Never>,
  timeoutNanoseconds: UInt64 = 150_000_000,
) async -> Bool {
  let waiter = Task {
    await task.value
    return true
  }
  defer { waiter.cancel() }

  return await withTaskGroup(of: Bool.self) { group in
    group.addTask {
      await waiter.value
    }
    group.addTask {
      try? await Task.sleep(nanoseconds: timeoutNanoseconds)
      return false
    }
    let completed = await group.next() ?? false
    group.cancelAll()
    return completed
  }
}

/// Feeds a steady RMS sample while advancing the clock by `duration` in
/// `steps` equal increments, yielding after each to keep the monitor in
/// lock-step with virtual time.
private func feedRMS(
  _ harness: borrowing MonitorHarness,
  linear: Float,
  for duration: Duration,
  steps: Int = 6,
) async {
  let stepDuration = duration / steps
  for _ in 0..<steps {
    harness.rmsContinuation.yield(linear)
    harness.clock.advance(by: stepDuration)
    await drain()
  }
  // Final frame at the end of the window so the monitor sees a post-advance
  // sample and re-evaluates at the new clock reading.
  harness.rmsContinuation.yield(linear)
  await drain()
}

// MARK: - Tests

@Suite("MicHealthMonitor", .serialized)
struct MicHealthMonitorTests {
  private let healthy: Float = 0.1  // ~-20 dBFS, comfortably above -60 dBFS
  private let silent: Float = 0.0  // floored to leastNormalMagnitude

  @Test
  func establishingHealthyBaseline_thenStaysHealthy() async throws {
    let harness = makeMonitor()

    let thresholds = MicHealthThresholds.testFast
    await feedRMS(harness, linear: healthy, for: thresholds.healthyMinDuration * 3 / 2)

    #expect(harness.monitor.currentState == .healthy)
    let events = await harness.monitor.finalize()
    #expect(events.isEmpty)

    await harness.teardown()
  }

  @Test
  func sustainedSilenceFromStart_firesAfterThreshold() async throws {
    let harness = makeMonitor()

    let thresholds = MicHealthThresholds.testFast
    await feedRMS(harness, linear: silent, for: thresholds.silenceMinDuration * 3 / 2)

    let state = harness.monitor.currentState
    #expect(state == .degraded(.sustainedSilence))

    let events = await harness.monitor.finalize()
    #expect(events.count == 1)
    #expect(events.first?.kind == .sustainedSilence)

    await harness.teardown()
  }

  @Test
  func sustainedSilenceShorterThanThreshold_doesNotFire() async throws {
    let harness = makeMonitor()

    let thresholds = MicHealthThresholds.testFast
    await feedRMS(harness, linear: silent, for: thresholds.silenceMinDuration / 2)

    let state = harness.monitor.currentState
    if case .degraded = state {
      Issue.record("unexpected degraded state: \(state)")
    }

    let events = await harness.monitor.finalize()
    #expect(events.isEmpty)

    await harness.teardown()
  }

  @Test
  func signalDropAfterHealthy_firesAsSignalDrop_notSilence() async throws {
    let harness = makeMonitor()

    let thresholds = MicHealthThresholds.testFast
    await feedRMS(harness, linear: healthy, for: thresholds.healthyMinDuration * 3 / 2)
    #expect(harness.monitor.currentState == .healthy)

    await feedRMS(harness, linear: silent, for: thresholds.dropDetectionDuration * 3 / 2)

    #expect(harness.monitor.currentState == .degraded(.signalDrop))
    let events = await harness.monitor.finalize()
    #expect(events.count == 1)
    #expect(events.first?.kind == .signalDrop)
    #expect(events.first?.kind != .sustainedSilence)

    await harness.teardown()
  }

  @Test
  func signalDropThenRecovery_emitsClosedInterval() async throws {
    let harness = makeMonitor()

    let thresholds = MicHealthThresholds.testFast
    await feedRMS(harness, linear: healthy, for: thresholds.healthyMinDuration * 3 / 2)
    await feedRMS(harness, linear: silent, for: thresholds.dropDetectionDuration * 3 / 2)
    await feedRMS(harness, linear: healthy, for: thresholds.recoveryMinDuration * 3 / 2)

    if case .degradedRecovered(let reason) = harness.monitor.currentState {
      #expect(reason == .signalDrop)
    } else {
      Issue.record("expected .degradedRecovered, got \(harness.monitor.currentState)")
    }

    let events = await harness.monitor.finalize()
    #expect(events.count == 1)
    #expect(events.first?.kind == .signalDrop)
    #expect(events.first?.endedAt != nil)

    await harness.teardown()
  }

  @Test
  func multipleSilenceWindows_emitMultipleClosedIntervals() async throws {
    let harness = makeMonitor()

    let thresholds = MicHealthThresholds.testFast
    await feedRMS(harness, linear: healthy, for: thresholds.healthyMinDuration * 3 / 2)
    await feedRMS(harness, linear: silent, for: thresholds.dropDetectionDuration * 3 / 2)
    await feedRMS(harness, linear: healthy, for: thresholds.recoveryMinDuration * 3 / 2)
    await feedRMS(harness, linear: silent, for: thresholds.dropDetectionDuration * 3 / 2)
    await feedRMS(harness, linear: healthy, for: thresholds.recoveryMinDuration * 3 / 2)

    let events = await harness.monitor.finalize()
    #expect(events.count == 2)
    for event in events {
      #expect(event.kind == .signalDrop)
      #expect(event.endedAt != nil)
      if let endedAt = event.endedAt {
        #expect(endedAt > event.startedAt)
      }
    }

    await harness.teardown()
  }

  @Test
  func degradedRecoveredState_isLatchedAcrossSession() async throws {
    let harness = makeMonitor()

    let thresholds = MicHealthThresholds.testFast
    // Establish baseline and then degrade once.
    await feedRMS(harness, linear: healthy, for: thresholds.healthyMinDuration * 3 / 2)
    await feedRMS(harness, linear: silent, for: thresholds.dropDetectionDuration * 3 / 2)
    await feedRMS(harness, linear: healthy, for: thresholds.recoveryMinDuration * 3 / 2)

    // After first recovery the state should be degradedRecovered, NOT healthy.
    if case .degradedRecovered = harness.monitor.currentState {
      // expected
    } else {
      Issue.record(
        "expected .degradedRecovered after first recovery, got \(harness.monitor.currentState)",
      )
    }

    // Brief silence (below threshold) should not reset the latch.
    await feedRMS(harness, linear: silent, for: thresholds.dropDetectionDuration / 3)
    // And the next healthy stretch must still resolve to .degradedRecovered.
    await feedRMS(harness, linear: healthy, for: thresholds.recoveryMinDuration * 3 / 2)

    if case .degradedRecovered = harness.monitor.currentState {
      // expected
    } else {
      Issue.record(
        "expected latched .degradedRecovered, got \(harness.monitor.currentState)",
      )
    }

    await harness.teardown()
  }

  @Test
  func finalizeWithOpenInterval_closesItAtCurrentClock() async throws {
    let harness = makeMonitor()

    let thresholds = MicHealthThresholds.testFast
    // Enter degraded state via sustained silence.
    await feedRMS(harness, linear: silent, for: thresholds.silenceMinDuration * 3 / 2)
    #expect(harness.monitor.currentState == .degraded(.sustainedSilence))

    // Advance the virtual clock past the degradation start without feeding
    // any further samples. finalize() must close the open interval at the
    // current clock reading.
    let extra: Duration = .milliseconds(40)
    harness.clock.advance(by: extra)

    let events = await harness.monitor.finalize()
    #expect(events.count == 1)
    let event = try #require(events.first)
    let endedAt = try #require(event.endedAt)
    // endedAt should be at or after the degradation's startedAt, and should
    // reflect the additional time that elapsed while the interval was open.
    #expect(endedAt >= event.startedAt)
    #expect(endedAt - event.startedAt >= 0.030)  // at least the advance we injected

    await harness.teardown()
  }

  @Test
  func cancelledRunLoop_finalizeStillReturnsAccumulatedEvents() async throws {
    let harness = makeMonitor()

    let thresholds = MicHealthThresholds.testFast
    // Get into a degraded state first.
    await feedRMS(harness, linear: silent, for: thresholds.silenceMinDuration * 3 / 2)
    #expect(harness.monitor.currentState == .degraded(.sustainedSilence))

    // Close the input streams and cancel the run task. Wait for it to exit.
    harness.rmsContinuation.finish()
    harness.routeContinuation.finish()
    harness.runTask.cancel()
    await harness.runTask.value

    // Advance the clock a bit and finalize. The event log must still be
    // intact and closed at the current clock reading.
    harness.clock.advance(by: .milliseconds(10))
    let events = await harness.monitor.finalize()
    #expect(!events.isEmpty)
    #expect(events.first?.kind == .sustainedSilence)
    #expect(events.first?.endedAt != nil)
  }

  @Test
  func runExitsWhenOneStreamFinishes() async throws {
    let harness = makeMonitor()

    harness.rmsContinuation.finish()
    await drain()

    #expect(await waitForCompletion(harness.runTask))

    await harness.teardown()
  }

  #if canImport(AVFoundation) && os(iOS)
    // MARK: - Route-event tests (iOS simulator only)
    //
    // `AudioRouteChangeEvent`, `AVAudioSession`, and
    // `AVAudioSession.RouteChangeReason` are iOS-only types (see
    // `AudioRouteChangeEvent.swift` — the iOS struct is `#if os(iOS)`).
    // These tests are compiled out on macOS host SwiftPM builds and must
    // be executed via the iOS simulator.

    private func makeRouteEvent(
      reason: AVAudioSession.RouteChangeReason,
    ) -> AudioRouteChangeEvent {
      // `AudioRouteChangeEvent.previousRoute` can only be constructed from a
      // real `AVAudioSessionRouteDescription`. The route-loss code path only
      // reads `previousRoute?.inputs.first?.name`, so passing `nil` is safe
      // — the monitor records `deviceName: nil`.
      AudioRouteChangeEvent(
        reason: reason,
        previousRoute: nil,
        session: AVAudioSession.sharedInstance(),
      )
    }

    @Test
    func routeLost_firesImmediatelyAsInstantaneous() async throws {
      let harness = makeMonitor()

      let thresholds = MicHealthThresholds.testFast
      await feedRMS(harness, linear: healthy, for: thresholds.healthyMinDuration * 3 / 2)
      #expect(harness.monitor.currentState == .healthy)

      harness.routeContinuation.yield(makeRouteEvent(reason: .oldDeviceUnavailable))
      await drain()

      if case .degraded(.routeLost) = harness.monitor.currentState {
        // expected — route loss is instantaneous, no threshold delay.
      } else {
        Issue.record(
          "expected .degraded(.routeLost), got \(harness.monitor.currentState)",
        )
      }

      let events = await harness.monitor.finalize()
      #expect(events.count == 1)
      #expect(events.first?.kind == .routeLost)

      await harness.teardown()
    }

    @Test
    func routeLostBeforeFirstRMS_usesElapsedTimeNotZero() async throws {
      let harness = makeMonitor()

      harness.clock.advance(by: .milliseconds(25))
      harness.routeContinuation.yield(makeRouteEvent(reason: .oldDeviceUnavailable))
      await drain()

      #expect(harness.monitor.currentState == .degraded(.routeLost(deviceName: nil)))

      let events = await harness.monitor.finalize()
      let event = try #require(events.first)
      #expect(event.kind == .routeLost)
      #expect(event.startedAt > 0)
      #expect(event.endedAt != nil)
      if let endedAt = event.endedAt {
        #expect(endedAt >= event.startedAt)
      }

      await harness.teardown()
    }

    @Test
    func routeLostThenNewRoute_doesNotAutoRecoverWithoutSignal() async throws {
      let harness = makeMonitor()

      let thresholds = MicHealthThresholds.testFast
      await feedRMS(harness, linear: healthy, for: thresholds.healthyMinDuration * 3 / 2)

      harness.routeContinuation.yield(makeRouteEvent(reason: .oldDeviceUnavailable))
      await drain()
      harness.routeContinuation.yield(makeRouteEvent(reason: .newDeviceAvailable))
      await drain()

      // No clock advance with healthy signal: still degraded.
      if case .degraded(.routeLost) = harness.monitor.currentState {
        // expected
      } else {
        Issue.record(
          "expected still .degraded(.routeLost) before healthy signal, got "
            + "\(harness.monitor.currentState)",
        )
      }

      // Now feed enough healthy signal to clear the route-loss degradation.
      await feedRMS(harness, linear: healthy, for: thresholds.recoveryMinDuration * 3 / 2)

      if case .degradedRecovered(let last) = harness.monitor.currentState {
        if case .routeLost = last {
          // expected
        } else {
          Issue.record("expected lastReason == .routeLost, got \(last)")
        }
      } else {
        Issue.record(
          "expected .degradedRecovered(.routeLost), got \(harness.monitor.currentState)",
        )
      }

      await harness.teardown()
    }
  #endif
}
