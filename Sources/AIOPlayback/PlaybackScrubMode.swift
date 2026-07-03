// © GoodHatsLLC

#if canImport(AVFoundation)
  import Foundation

  /// Caller intent for a playback scrub.
  ///
  /// Use ``interactive`` for high-frequency drag updates where the UI owns the
  /// in-flight playhead preview. Use ``committed`` for a final seek, tap-to-seek,
  /// remote-command seek, or any other scrub that should immediately resume the
  /// normal playback observation cadence.
  public enum PlaybackScrubMode: Hashable, Sendable {
    case committed
    case interactive

    var updatesPlaybackPolling: Bool {
      switch self {
      case .committed:
        true
      case .interactive:
        false
      }
    }
  }
#endif
