// © GoodHatsLLC

#if canImport(AVFoundation)
  public import AIOAudioSession
  public import Foundation

  /// The unified event surface emitted by AudioIO's audio engine
  /// (``AIOEngine/events``).
  ///
  /// Consumers subscribe via `for await event in engine.events { ... }` and
  /// pattern-match on the case they care about. This is the canonical
  /// subscription API for engine notifications.
  ///
  /// Emitted cases:
  /// - ``error(_:)`` — engine-level failures the engine couldn't surface
  ///   via a `throws` signature (tap-thread conversion failures, async
  ///   drain failures, session deactivation failures).
  /// - ``recordingStarted(url:format:)`` — initial recording start or
  ///   segment rotation; carries the active recording file URL and its
  ///   format string.
  /// - ``recordingCompleted`` — recording stopped cleanly (user-initiated
  ///   stop).
  /// - ``recordingFailed`` — recording stopped due to an engine-side
  ///   failure; usually pairs with an ``error(_:)`` event describing the
  ///   cause.
  /// - ``recordingInterruption(_:)`` — route change continuation, graceful
  ///   stop, or interruption-driven stop.
  /// - ``reconciliationFailed(desiredRecording:)`` — the engine couldn't
  ///   reach the desired recording state within the reconciliation
  ///   timeout. Only relevant when using the
  ///   ``AIOEngine/setDesiredRecordingState(_:configuration:)`` entry
  ///   point.
  /// - ``playbackStateChanged(_:)`` — play/pause/stop transitions
  ///   (excludes time ticks).
  /// - ``playbackUpdated(_:)`` — every playback observation including
  ///   time ticks. Mirror this into a local `@Observable` store if you
  ///   need SwiftUI bindings to react to playback position.
  public enum AudioIOEvent: Sendable {
    /// An engine-level error that the engine couldn't surface via a
    /// `throws` signature — typically because the failure originated on
    /// a real-time / tap-side thread, during async drain, or during
    /// session deactivation initiated by a state transition.
    case error(any AudioIOError)

    /// A recording started (either the initial start or a segment
    /// rotation).
    ///
    /// - Parameter url: The URL of the active recording file.
    /// - Parameter format: The active recording file's format identifier.
    case recordingStarted(url: URL, format: String)

    /// A recording stopped cleanly via a user-initiated stop.
    case recordingCompleted

    /// A recording stopped due to an engine-side failure. Usually pairs
    /// with an ``error(_:)`` event describing the cause.
    case recordingFailed

    /// A recording interruption occurred — a route change continuation,
    /// a graceful stop, or an interruption-driven stop.
    case recordingInterruption(AIOEngine.RecordingInterruption)

    /// The engine couldn't reach the desired recording state within the
    /// reconciliation timeout.
    ///
    /// Only relevant when using the
    /// ``AIOEngine/setDesiredRecordingState(_:configuration:)`` entry
    /// point; the canonical
    /// ``AIOEngine/startRecording(configuration:)`` surface returns
    /// failures directly via typed throws.
    ///
    /// - Parameter desiredRecording: The recording state the engine was
    ///   attempting to reach (`true` for "start", `false` for "stop").
    case reconciliationFailed(desiredRecording: Bool)

    /// The playback item or playback state changed (play/pause/stop),
    /// excluding time ticks.
    case playbackStateChanged(AIOEngine.Playback?)

    /// Every playback observation, including time ticks.
    ///
    /// Use this to mirror playback state into a local `@Observable`
    /// stored property so that SwiftUI observation reliably fires for
    /// downstream views.
    case playbackUpdated(AIOEngine.Playback?)
  }
#endif
