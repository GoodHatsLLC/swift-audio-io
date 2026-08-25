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
  /// underlying `AudioRouteChange` carried one.
  public let deviceName: String?

  /// Free-form detail — for a pause, why capture paused and, on the closing
  /// event, how long the gap was in wall-clock seconds.
  public let note: String?

  public init(
    kind: PendingTrackEventKind,
    startedAt: TimeInterval,
    endedAt: TimeInterval?,
    deviceName: String?,
    note: String? = nil,
  ) {
    self.kind = kind
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.deviceName = deviceName
    self.note = note
  }
}

/// Raw string values intentionally mirror
/// `AppModels.TrackEventKind.rawValue` so the T6 mapping is a trivial
/// `TrackEventKind(rawValue: pending.kind.rawValue)`.
public enum PendingTrackEventKind: String, Sendable, Equatable {
  case sustainedSilence = "mic.sustained_silence"
  case signalDrop = "mic.signal_drop"
  case routeLost = "mic.route_lost"
  /// Capture paused — the OS took the session, media services went away, or
  /// no route could feed the tap — and resumed into the same file. The event
  /// spans the pause in *audio* time (a point, since no frames were written)
  /// and its note carries the wall-clock gap, so the gap is represented
  /// honestly rather than fabricated as silence.
  case recordingPaused = "recording.paused"
  /// Bring-up changed something about the request in order to start (an
  /// unavailable preferred input, a container that yielded to the rate).
  case captureSubstitution = "capture.substitution"
}
