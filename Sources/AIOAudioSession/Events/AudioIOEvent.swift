// © GoodHatsLLC

#if canImport(AVFoundation)
  public import Foundation
  public import Tools

  /// The unified event surface emitted by AudioIO's audio engine
  /// (`AIOEngine.events`).
  ///
  /// Consumers subscribe via `for await event in engine.events { ... }` and
  /// pattern-match on the case they care about. This is the canonical
  /// subscription API for engine notifications; the closure-style
  /// `onRecording*` / `onPlayback*` callbacks on `AIOEngine` remain for
  /// installation-time observers (e.g. crash-tracking handlers that need
  /// chained-observer semantics) but new code should prefer this stream.
  ///
  /// Currently emitted:
  /// - ``error(_:)``: every engine-level failure that previously flowed
  ///   through the now-removed `errors: AsyncBroadcaster<any Error>`
  ///   stream — tap conversion failures, audio-session deactivation
  ///   failures, recording file-write failures.
  ///
  /// Future cases (tracked under M3 follow-ups) will subsume the closure
  /// callbacks for recording lifecycle (`recordingStarted`,
  /// `recordingCompleted`, `recordingFailed`, `segmentCompleted`,
  /// `recordingInterruption`) and playback lifecycle.
  public enum AudioIOEvent: Sendable {
    /// An engine-level error that the engine couldn't surface via a
    /// `throws` signature — typically because the failure originated on
    /// a real-time / tap-side thread, during async drain, or during
    /// session deactivation initiated by a state transition.
    case error(any AudioIOError)
  }
#endif
