// © GoodHatsLLC

#if canImport(AVFoundation)
  import Foundation
  public import Tools

  /// Errors from the underlying audio session and engine bring-up — orthogonal
  /// to whether the consumer is recording or playing back. Both
  /// ``RecordingError`` and ``PlaybackError`` wrap `SessionError` via their
  /// `.session(_:)` cases when a session-level failure surfaces in those flows.
  public enum SessionError: AudioIOError, Equatable {
    /// AVFoundation `AVAudioSession` operations that can fail.
    public enum Operation: String, Sendable, Equatable, CustomStringConvertible {
      case setCategory
      case setPreferredSampleRate
      case setPreferredIOBufferDuration
      case setPreferredInputNumberOfChannels
      case setAllowHapticsAndSystemSoundsDuringRecording
      case setPrefersNoInterruptionsFromSystemAlerts
      case setPrefersInterruptionOnRouteDisconnect
      case setActive
      case setPreferredInput
      case overrideOutputAudioPort

      public var description: String { rawValue }
    }

    /// The audio session is not ready (typically: not yet activated, or
    /// torn down while the engine was mid-bring-up).
    case notReady(details: String)

    /// A system audio-session operation failed.
    case operationFailed(operation: Operation, error: ErrorContext)

    /// The requested preferred recording input was not available to the active
    /// audio session.
    case preferredInputUnavailable(id: String, name: String)

    /// The audio session accepted a preferred input request, but the current
    /// route has not yet switched to that input.
    case preferredInputRouteMismatch(id: String, name: String, currentInputIDs: [String])

    /// The underlying `AVAudioEngine` failed to start.
    case engineStartFailed(error: ErrorContext)

    public var errorDescription: String? {
      switch self {
      case .notReady(let details):
        "Audio session not ready: \(details)"
      case .operationFailed(let operation, let error):
        "Audio session operation '\(operation)' failed: \(error)"
      case .preferredInputUnavailable(let id, let name):
        "Preferred input '\(name)' (\(id)) is not available"
      case .preferredInputRouteMismatch(let id, let name, let currentInputIDs):
        "Preferred input '\(name)' (\(id)) is not the current route. Current inputs: \(currentInputIDs.joined(separator: ", "))"
      case .engineStartFailed(let error):
        "Audio engine failed to start: \(error)"
      }
    }

    public var description: String {
      errorDescription ?? String(describing: self)
    }

    /// Returns `true` if this error might be transient and worth retrying.
    public var isTransient: Bool {
      switch self {
      case .notReady, .preferredInputRouteMismatch: true
      default: false
      }
    }
  }
#endif
