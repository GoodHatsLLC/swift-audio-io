// © GoodHatsLLC

internal import AIOAudioSession
internal import Foundation
internal import Tools

#if canImport(AVFAudio)
  internal import AVFAudio
#endif

#if canImport(Darwin)
  import Darwin
#endif

// MARK: - Clock adapter

/// Opens the `any Clock<Duration>` existential once at construction time so
/// the monitor can operate on plain `TimeInterval`s relative to a fixed
/// zero. The generic entry point captures `clock` inside the returned
/// closure, which is the canonical way to persist an existential clock's
/// `Instant` type across calls without leaking it through the actor's API.
///
/// The closure references `clock` and the original `start` instant by
/// value; both are `Sendable` (a Clock conformer is always Sendable, and
/// `InstantProtocol` carries value semantics).
private struct MicHealthClockAdapter: Sendable {
  /// Returns the number of seconds elapsed between adapter construction
  /// and the current clock reading. Always monotonic for a well-behaved
  /// clock.
  let nowSeconds: @Sendable () -> TimeInterval
}

extension MicHealthClockAdapter {
  fileprivate static func make<C: Clock>(_ clock: C) -> MicHealthClockAdapter
  where C.Duration == Duration {
    let origin = clock.now
    return MicHealthClockAdapter(
      nowSeconds: {
        let delta = origin.duration(to: clock.now)
        return delta.toTimeInterval
      },
    )
  }
}

extension Duration {
  /// Seconds as a `Double`. Hand-rolled to avoid pulling a utility out of
  /// `Tools` and to keep the conversion inline-visible in this file.
  fileprivate var toTimeInterval: TimeInterval {
    let components = self.components
    return TimeInterval(components.seconds)
      + TimeInterval(components.attoseconds) / 1e18
  }
}

// MARK: - Interval bookkeeping

/// Internal event log row. Each entry has a start time in seconds from the
/// monitor's zero instant. `endedAt == nil` means still open; `finalize()`
/// closes any remaining open intervals at the current clock reading.
private struct MicHealthInterval: Sendable, Equatable {
  var kind: PendingTrackEventKind
  var startedAt: TimeInterval
  var endedAt: TimeInterval?
  var deviceName: String?
}

// MARK: - Route event classification

private enum RouteClassification: Sendable, Equatable {
  case lost(deviceName: String?)
  case gained
  case other
}

extension AudioRouteChangeEvent {
  fileprivate var micHealthClassification: RouteClassification {
    #if os(iOS)
      switch reason {
      case .oldDeviceUnavailable:
        return .lost(deviceName: previousRoute?.inputs.first?.name)
      case .newDeviceAvailable:
        return .gained
      default:
        return .other
      }
    #else
      // macOS's `AudioRouteChangeEvent` has no reason discriminator; we
      // classify every event as "other" and let the feature effectively
      // no-op on macOS. Tests still validate the iOS code path because
      // the iOS route event type is imported unconditionally on iOS.
      return .other
    #endif
  }
}

// MARK: - Monitor

/// A deterministic, injection-testable mic-health state machine.
///
/// The monitor consumes two asynchronous inputs (RMS + route events) concurrently
/// inside `run()`. State transitions update a `nonisolated` `Mut`-wrapped
/// `MicHealthState` so the recording banner can read the current state
/// synchronously from MainActor without crossing an `await`. The event log
/// is pulled out once at stop time via `finalize()`.
///
/// The monitor never throws. Stream termination or cancellation causes
/// `run()` to exit gracefully; the accumulated event log remains readable
/// via `finalize()`.
public actor MicHealthMonitor {
  // Constructor-injected.
  private let thresholds: MicHealthThresholds
  private let rms: AsyncSignalStream<Float>
  private let routeEvents: AsyncSignalStream<AudioRouteChangeEvent>
  private let clockAdapter: MicHealthClockAdapter
  /// Absolute seconds at monitor construction time. All event timestamps are
  /// relative to this anchor so route-loss events that arrive before the first
  /// RMS frame still carry real elapsed time.
  private let sessionStartSeconds: TimeInterval

  // Published state. `Mut` is a value-type wrapper over `Mutex`/unfair-lock
  // that lets us read/write synchronously from a `nonisolated` accessor
  // while keeping actor-isolated code races-free.
  private nonisolated let publishedState: Mut<MicHealthState>

  // Internal state (actor-isolated).
  private var intervals: [MicHealthInterval] = []
  private var hasEverBeenHealthy = false
  private var hasEverBeenDegraded = false
  private var lastReason: MicHealthReason? = nil
  /// Tracks whether at least one RMS frame has been observed. The first RMS
  /// frame transitions the monitor from `.uninitialized` to `.establishing`.
  private var hasObservedRMS = false
  /// When we started observing continuous below-threshold frames, or `nil`
  /// if the current frame was above threshold.
  private var silenceRunStartSeconds: TimeInterval? = nil
  /// When we started observing continuous above-threshold frames, or `nil`
  /// if the current frame was below threshold.
  private var healthyRunStartSeconds: TimeInterval? = nil
  /// Set to true when a `.newDeviceAvailable` route event arrives. The
  /// monitor clears `.routeLost` only when this is true AND healthy signal
  /// persists for `recoveryMinDuration`.
  private var routeRecoveryArmed = false

  public init(inputs: MicHealthInputs) {
    thresholds = inputs.thresholds
    rms = inputs.rms
    routeEvents = inputs.routeEvents
    clockAdapter = Self.makeAdapter(from: inputs.clock)
    sessionStartSeconds = clockAdapter.nowSeconds()
    publishedState = Mut(.uninitialized)
  }

  /// Opens the `any Clock<Duration>` existential exactly once.
  private static func makeAdapter(from clock: any Clock<Duration>)
    -> MicHealthClockAdapter
  {
    // Generic helper that opens the existential so we can call Clock API
    // on a statically-known type.
    func open<C: Clock>(_ c: C) -> MicHealthClockAdapter
    where C.Duration == Duration {
      MicHealthClockAdapter.make(c)
    }
    return open(clock)
  }

  /// Live snapshot of the monitor's public state. Safe to call
  /// synchronously from any isolation domain.
  public nonisolated var currentState: MicHealthState {
    publishedState.withLock { $0 }
  }

  internal func recordRMSForTesting(_ linearRMS: Float) {
    handleRMS(linearRMS)
  }

  internal func recordRouteForTesting(_ event: AudioRouteChangeEvent) {
    handleRoute(event)
  }

  /// Consumes the injected streams until they end or `run()`'s Task is
  /// cancelled. Runs one child per stream and exits as soon as either stream
  /// ends so the monitor does not hang waiting on a dead source.
  public func run() async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.consumeRMS() }
      group.addTask { await self.consumeRoute() }
      await group.next()
      group.cancelAll()
    }
  }

  /// Closes any still-open interval at the current clock reading and
  /// returns the accumulated event log translated to `PendingTrackEvent`.
  public func finalize() -> [PendingTrackEvent] {
    let now = clockAdapter.nowSeconds()
    for index in intervals.indices where intervals[index].endedAt == nil {
      let nowRelative = max(0, now - sessionStartSeconds)
      intervals[index].endedAt = nowRelative
    }
    return intervals.map {
      PendingTrackEvent(
        kind: $0.kind,
        startedAt: $0.startedAt,
        endedAt: $0.endedAt,
        deviceName: $0.deviceName,
      )
    }
  }

  // MARK: - Stream consumers

  private func consumeRMS() async {
    for await sample in rms {
      if Task.isCancelled { return }
      handleRMS(sample)
    }
  }

  private func consumeRoute() async {
    for await event in routeEvents {
      if Task.isCancelled { return }
      handleRoute(event)
    }
  }

  // MARK: - RMS path

  private func handleRMS(_ linearRMS: Float) {
    let nowAbs = clockAdapter.nowSeconds()
    if !hasObservedRMS {
      hasObservedRMS = true
      setState(.establishing)
    }
    let nowRelative = max(0, nowAbs - sessionStartSeconds)
    let dbfs = Self.toDBFS(linearRMS)
    let isAboveThreshold = dbfs > thresholds.silenceDBFS

    if isAboveThreshold {
      silenceRunStartSeconds = nil
      if healthyRunStartSeconds == nil {
        healthyRunStartSeconds = nowRelative
      }
      evaluateHealthyRun(at: nowRelative)
    } else {
      healthyRunStartSeconds = nil
      // Signal loss resets route-recovery arming — the monitor requires
      // continuous healthy signal AFTER the new-device event, not a
      // brief above-threshold blip during the silence run.
      if case .degraded(.routeLost) = currentStateInternal {
        routeRecoveryArmed = false
      }
      if silenceRunStartSeconds == nil {
        silenceRunStartSeconds = nowRelative
      }
      evaluateSilenceRun(at: nowRelative)
    }
  }

  private func evaluateHealthyRun(at nowRelative: TimeInterval) {
    guard let runStart = healthyRunStartSeconds else { return }
    let elapsed = nowRelative - runStart
    let required: TimeInterval
    switch currentStateInternal {
    case .uninitialized, .establishing, .healthy:
      required = thresholds.healthyMinDuration.toTimeInterval
    case .degraded(.routeLost):
      // Route loss requires BOTH a new-route event AND sustained signal.
      required = thresholds.recoveryMinDuration.toTimeInterval
      guard routeRecoveryArmed else { return }
    case .degraded, .degradedRecovered:
      required = thresholds.recoveryMinDuration.toTimeInterval
    }
    guard elapsed >= required else { return }
    transitionToHealthyLike(at: nowRelative)
  }

  private func evaluateSilenceRun(at nowRelative: TimeInterval) {
    guard let runStart = silenceRunStartSeconds else { return }
    let elapsed = nowRelative - runStart
    switch currentStateInternal {
    case .uninitialized:
      // Should never hit — handleRMS sets .establishing on first frame.
      return
    case .establishing:
      // Cold start: classify as .sustainedSilence.
      guard elapsed >= thresholds.silenceMinDuration.toTimeInterval else {
        return
      }
      beginDegraded(reason: .sustainedSilence, at: nowRelative)
    case .healthy, .degradedRecovered:
      // Post-healthy: classify as .signalDrop.
      guard elapsed >= thresholds.dropDetectionDuration.toTimeInterval else {
        return
      }
      beginDegraded(reason: .signalDrop, at: nowRelative)
    case .degraded:
      // Already degraded — the current silence run just keeps the open
      // interval alive; nothing to do until the signal returns.
      return
    }
  }

  // MARK: - Route path

  private func handleRoute(_ event: AudioRouteChangeEvent) {
    switch event.micHealthClassification {
    case .lost(let deviceName):
      handleRouteLost(deviceName: deviceName)
    case .gained:
      handleRouteGained()
    case .other:
      return
    }
  }

  private func handleRouteLost(deviceName: String?) {
    // Route events are instantaneous: trigger regardless of prior state,
    // and carry the device name in the reason.
    routeRecoveryArmed = false
    beginDegraded(
      reason: .routeLost(deviceName: deviceName),
      at: nowRelativeSeconds(),
    )
  }

  private func handleRouteGained() {
    if case .degraded(.routeLost) = currentStateInternal {
      routeRecoveryArmed = true
    }
  }

  // MARK: - State transitions

  private var currentStateInternal: MicHealthState {
    publishedState.withLock { $0 }
  }

  private func setState(_ new: MicHealthState) {
    publishedState.withLock { $0 = new }
  }

  private func beginDegraded(reason: MicHealthReason, at nowRelative: TimeInterval) {
    // Idempotent per reason: if already degraded with an equivalent reason
    // key, don't open a duplicate interval.
    if case .degraded(let existing) = currentStateInternal,
      existing.canonicalKey == reason.canonicalKey
    {
      return
    }

    // Close any prior open interval (defensive — should be none outside
    // of race cases).
    closeOpenIntervals(at: nowRelative)

    hasEverBeenDegraded = true
    lastReason = reason
    let kind: PendingTrackEventKind
    switch reason {
    case .sustainedSilence: kind = .sustainedSilence
    case .signalDrop: kind = .signalDrop
    case .routeLost: kind = .routeLost
    }
    let device: String? = {
      if case .routeLost(let name) = reason { return name }
      return nil
    }()
    intervals.append(
      MicHealthInterval(
        kind: kind,
        startedAt: nowRelative,
        endedAt: nil,
        deviceName: device,
      ),
    )
    setState(.degraded(reason))
  }

  private func transitionToHealthyLike(at nowRelative: TimeInterval) {
    closeOpenIntervals(at: nowRelative)
    hasEverBeenHealthy = true
    if hasEverBeenDegraded, let last = lastReason {
      setState(.degradedRecovered(lastReason: last))
    } else {
      setState(.healthy)
    }
    routeRecoveryArmed = false
  }

  private func closeOpenIntervals(at nowRelative: TimeInterval) {
    for index in intervals.indices where intervals[index].endedAt == nil {
      intervals[index].endedAt = max(nowRelative, intervals[index].startedAt)
    }
  }

  private func nowRelativeSeconds() -> TimeInterval {
    let nowAbs = clockAdapter.nowSeconds()
    return max(0, nowAbs - sessionStartSeconds)
  }

  // MARK: - dBFS conversion

  /// Converts a linear RMS amplitude in `[0, 1]` to dBFS, flooring the
  /// input at `Float.leastNormalMagnitude` so `log10(0)` becomes a very
  /// negative but finite number rather than `-infinity`.
  private static func toDBFS(_ linear: Float) -> Float {
    let floored = max(linear, Float.leastNormalMagnitude)
    #if canImport(Darwin)
      return 20 * log10f(floored)
    #else
      return 20 * Float(Foundation.log10(Double(floored)))
    #endif
  }
}
