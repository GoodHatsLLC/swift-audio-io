// © GoodHatsLLC

#if canImport(AVFoundation)
  public import Foundation
  public import Tools

  // PlaybackError exposes `URL?` in its public API (`fileReadFailed`).

  /// Errors that can surface from AudioIO's playback flows
  /// (`AIOEngine.play(url:)`, segment playback, and scrub/seek).
  public enum PlaybackError: AudioIOError, Equatable {
    /// Playback cannot start because the engine is currently recording.
    case cannotPlayWhileRecording

    /// A scrub time was requested outside the allowed `0..<1` progress range.
    case invalidScrubTime(value: Double)

    /// The specified time range is invalid for segment playback (e.g. start
    /// after end, or wholly outside the file).
    case invalidTimeRange

    /// Could not open the requested audio file for reading.
    case fileReadFailed(url: URL?, error: ErrorContext)

    /// A session-level failure surfaced during playback bring-up. Wraps
    /// ``SessionError`` so callers can pattern-match either the playback
    /// trigger or the underlying session failure.
    case session(SessionError)

    public var errorDescription: String? {
      switch self {
      case .cannotPlayWhileRecording:
        "Cannot play audio while recording"
      case .invalidScrubTime(let value):
        "Progress can only be scrubbed between 0..<1. (value: \(value))"
      case .invalidTimeRange:
        "The specified time range is invalid"
      case .fileReadFailed(let url, let error):
        "Failed to open audio file for reading \(url?.lastPathComponent ?? "missing URL"): \(error)"
      case .session(let sessionError):
        sessionError.errorDescription
      }
    }

    public var description: String {
      errorDescription ?? String(describing: self)
    }

    /// Returns `true` if this error might be transient and worth retrying.
    public var isTransient: Bool {
      switch self {
      case .session(let sessionError): sessionError.isTransient
      default: false
      }
    }
  }
#endif
