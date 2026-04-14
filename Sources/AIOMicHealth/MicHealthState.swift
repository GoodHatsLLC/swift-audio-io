// © GoodHatsLLC

/// Live state surfaced by `MicHealthMonitor` to the recording banner.
///
/// The monitor keeps this value inside an internal `Mut<MicHealthState>` so
/// it is readable synchronously from MainActor without crossing an `await`.
public enum MicHealthState: Sendable, Equatable {
  /// No RMS frame has been observed yet.
  case uninitialized

  /// First RMS frame arrived but the monitor has not yet accumulated enough
  /// above-threshold signal to call the input healthy.
  case establishing

  /// Input has been above threshold for `healthyMinDuration`.
  case healthy

  /// Input is currently failing. The reason describes *why*.
  case degraded(MicHealthReason)

  /// Input was degraded earlier in the session but has since returned to
  /// healthy. This state is latched — once the monitor has entered
  /// `.degraded`, any future healthy stretch lands here rather than
  /// `.healthy`. This drives the banner's "Audio recovered — tap to
  /// dismiss" terminal state.
  case degradedRecovered(lastReason: MicHealthReason)
}

/// Concrete reasons for a `.degraded` transition.
public enum MicHealthReason: Sendable, Equatable, Hashable {
  /// The input produced only below-threshold frames before the monitor had
  /// ever observed a healthy stretch.
  case sustainedSilence

  /// The input went silent *after* the monitor had already reached
  /// `.healthy`.
  case signalDrop

  /// An `AVAudioSession` route change reported a disconnected input. The
  /// device name (if any) is preserved for UI strings.
  case routeLost(deviceName: String?)

  /// Coarser discriminator for "fired at most once per reason kind"
  /// haptic/telemetry semantics (T7). Route loss collapses to a single key
  /// regardless of device name.
  public var canonicalKey: MicHealthReasonKey {
    switch self {
    case .sustainedSilence: .sustainedSilence
    case .signalDrop: .signalDrop
    case .routeLost: .routeLost
    }
  }
}

/// Canonicalised reason key. Useful for "fire at most once per session per
/// reason kind" rate limiting where the specific route-loss device name is
/// not meaningful.
public enum MicHealthReasonKey: Sendable, Hashable {
  case sustainedSilence
  case signalDrop
  case routeLost
}
