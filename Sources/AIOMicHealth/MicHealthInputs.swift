// © GoodHatsLLC

public import AIOAudioSession
public import Tools

/// Dependency container injected into `MicHealthMonitor.init`.
///
/// All three asynchronous inputs are consumer-owned (the monitor drives a
/// single `for await` loop on each). The `clock` parameter gives tests a hook
/// to run the state machine synchronously against a controllable `TestClock`.
public struct MicHealthInputs: Sendable {
  /// Linear-amplitude RMS samples in `[0, 1]`. The monitor converts to
  /// dBFS at the comparison site.
  public let rms: AsyncSignalStream<Float>

  /// Audio-session route change events. On iOS these are produced from
  /// `AVAudioSession` notifications; on macOS the type is a degenerate
  /// value and the monitor will simply ignore it.
  public let routeEvents: AsyncSignalStream<AudioRouteChange>

  /// Clock used for both "now" readings and interval bookkeeping.
  public let clock: any Clock<Duration>

  /// Tunable thresholds. Use `MicHealthThresholds.testFast` in tests.
  public let thresholds: MicHealthThresholds

  public init(
    rms: AsyncSignalStream<Float>,
    routeEvents: AsyncSignalStream<AudioRouteChange>,
    clock: any Clock<Duration>,
    thresholds: MicHealthThresholds,
  ) {
    self.rms = rms
    self.routeEvents = routeEvents
    self.clock = clock
    self.thresholds = thresholds
  }
}
