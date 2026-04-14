// © GoodHatsLLC

public import Foundation

/// A mic-health event produced by `MicHealthMonitor.finalize()`, awaiting a
/// `trackID` stamp from the integration layer (T6).
///
/// AIO lives below `AppModels` in the dependency graph, so it cannot refer
/// to `AppModels.TrackEvent` directly. The integration layer maps each
/// `PendingTrackEvent` to a `TrackEvent` by copying the raw `kind` string
/// into `TrackEventKind.rawValue`.
public struct PendingTrackEvent: Sendable, Equatable {
  public let kind: PendingTrackEventKind

  /// Seconds from the monitor's start instant.
  public let startedAt: TimeInterval

  /// Seconds from the monitor's start instant, or `nil` if the interval is
  /// still open. `finalize()` closes any still-open interval at the current
  /// clock time before returning.
  public let endedAt: TimeInterval?

  /// Human-readable device name associated with a route-lost event, if the
  /// underlying `AudioRouteChangeEvent` carried one.
  public let deviceName: String?

  public init(
    kind: PendingTrackEventKind,
    startedAt: TimeInterval,
    endedAt: TimeInterval?,
    deviceName: String?,
  ) {
    self.kind = kind
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.deviceName = deviceName
  }
}

/// Raw string values intentionally mirror
/// `AppModels.TrackEventKind.rawValue` so the T6 mapping is a trivial
/// `TrackEventKind(rawValue: pending.kind.rawValue)`.
public enum PendingTrackEventKind: String, Sendable, Equatable {
  case sustainedSilence = "mic.sustained_silence"
  case signalDrop = "mic.signal_drop"
  case routeLost = "mic.route_lost"
}
