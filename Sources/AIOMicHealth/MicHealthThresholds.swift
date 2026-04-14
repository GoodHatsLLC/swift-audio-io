// © GoodHatsLLC

/// Tunable thresholds that control the `MicHealthMonitor` state machine.
///
/// `silenceDBFS` is compared against the RMS stream after converting linear
/// amplitude to dBFS. All durations use Swift's `Duration` type so tests can
/// substitute compressed values via `testFast` without altering any call
/// sites.
public struct MicHealthThresholds: Sendable, Equatable {
  /// Amplitude (in dBFS) below which a frame is considered silent.
  ///
  /// The RMS stream delivers linear amplitudes in `[0, 1]`. The monitor
  /// converts at the comparison site via
  /// `20 * log10(max(rms, Float.leastNormalMagnitude))`, so the floor avoids
  /// `log10(0) = -inf`.
  public var silenceDBFS: Float

  /// Minimum continuous silence before a *cold-start* failure is classified
  /// as sustained silence (`.degraded(.sustainedSilence)`).
  public var silenceMinDuration: Duration

  /// Minimum continuous silence after the monitor has already reached
  /// `.healthy` before a failure is classified as a signal drop
  /// (`.degraded(.signalDrop)`).
  public var dropDetectionDuration: Duration

  /// Minimum continuous above-threshold signal before the monitor first
  /// transitions to `.healthy`.
  public var healthyMinDuration: Duration

  /// Minimum continuous above-threshold signal before the monitor leaves
  /// a degraded state and reports `.degradedRecovered`.
  public var recoveryMinDuration: Duration

  public init(
    silenceDBFS: Float,
    silenceMinDuration: Duration,
    dropDetectionDuration: Duration,
    healthyMinDuration: Duration,
    recoveryMinDuration: Duration,
  ) {
    self.silenceDBFS = silenceDBFS
    self.silenceMinDuration = silenceMinDuration
    self.dropDetectionDuration = dropDetectionDuration
    self.healthyMinDuration = healthyMinDuration
    self.recoveryMinDuration = recoveryMinDuration
  }

  /// Production defaults derived from the mic-health-detection spec.
  public static let `default` = MicHealthThresholds(
    silenceDBFS: -60.0,
    silenceMinDuration: .seconds(3),
    dropDetectionDuration: .seconds(2),
    healthyMinDuration: .milliseconds(1500),
    recoveryMinDuration: .milliseconds(1500),
  )

  /// Compressed thresholds for deterministic unit tests. Durations are
  /// ~100x smaller than production so a full state-machine traversal stays
  /// well under a second while leaving enough headroom for clock resolution.
  public static let testFast = MicHealthThresholds(
    silenceDBFS: -60.0,
    silenceMinDuration: .milliseconds(30),
    dropDetectionDuration: .milliseconds(20),
    healthyMinDuration: .milliseconds(15),
    recoveryMinDuration: .milliseconds(15),
  )
}
