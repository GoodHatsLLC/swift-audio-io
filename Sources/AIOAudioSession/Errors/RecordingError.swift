// © GoodHatsLLC

#if canImport(AVFoundation)
  public import Foundation
  public import Tools

  /// Errors that can surface from AudioIO's recording flows
  /// (`AIOEngine.startRecording`, `stopRecording`, `rotateRecordingFile`,
  /// tap install/reinstall, and recording-file I/O).
  public enum RecordingError: AudioIOError, Equatable {
    /// Recording-side file I/O operations that can fail.
    public enum FileOperation: String, Sendable, Equatable, CustomStringConvertible {
      case openForWriting
      case write

      public var description: String { rawValue }
    }

    /// The operation could not be completed because the engine is not
    /// currently recording.
    case notRecording

    /// The operation could not be completed because the engine is already
    /// recording.
    case alreadyRecording

    /// A generic recording-engine failure — typically a "shouldn't happen"
    /// guard such as a weak-self deinit during reconfiguration.
    case engineError

    /// The audio format conversion in the recording tap failed.
    case formatConversionFailed

    /// The hardware does not support the requested recording configuration.
    case hardwareNotSupported

    /// The recording configuration is invalid.
    case invalidConfiguration(details: String)

    /// The requested recording channel count exceeds the selected
    /// format/runtime capacity.
    case unsupportedChannelCount(requested: Int, maximum: Int)

    /// The selected output encoder does not support the requested sample rate.
    case unsupportedEncodedSampleRate(
      fileFormat: FileFormat,
      sampleRate: Double,
      supportedSampleRates: [Double],
    )

    /// A recording-side audio-file operation failed.
    case fileFailed(operation: FileOperation, url: URL?, error: ErrorContext)

    /// The requested capture source is unavailable — e.g. system-audio capture
    /// permission was denied, or the source is not present on this machine.
    /// Terminal: retrying without user/system action is noise.
    case captureSourceUnavailable(details: String)

    /// The capture source failed in a way the caller must resolve by changing
    /// the source, its options, or the format. Carries a short source
    /// description string rather than the source enum to keep equality / error
    /// output / ABI stable. Terminal.
    case captureSourceFailed(sourceDescription: String, details: String)

    /// A Core Audio (HAL) operation failed with an `OSStatus` that has no more
    /// specific mapping. Surfaced (logged + emitted) rather than swallowed.
    /// Terminal by default.
    case coreAudioFailed(operation: String, osStatus: Int32, details: String)

    /// A session-level failure surfaced during recording bring-up or tap
    /// install. Wraps ``SessionError`` so callers can pattern-match either
    /// the recording-specific cause or the underlying session failure.
    case session(SessionError)

    public var errorDescription: String? {
      switch self {
      case .notRecording:
        return "Not currently recording"
      case .alreadyRecording:
        return "Already recording"
      case .engineError:
        return "Recording engine error"
      case .formatConversionFailed:
        return "Failed to convert audio format for recording"
      case .hardwareNotSupported:
        return "Hardware configuration not supported"
      case .invalidConfiguration(let details):
        return "The recording configuration was not valid. \(details)"
      case .unsupportedChannelCount(let requested, let maximum):
        return
          "Recording \(requested)-channel audio is not supported by the selected format/runtime. The current maximum is \(maximum) channels."
      case .unsupportedEncodedSampleRate(let fileFormat, let sampleRate, let supportedRates):
        let requested = Int((sampleRate / 1000).rounded())
        let supportedDescription =
          supportedRates
          .map { Int(($0 / 1000).rounded()) }
          .map { "\($0)kHz" }
          .joined(separator: ", ")
        return
          "The selected \(fileFormat.description) format does not support \(requested)kHz. Supported rates: \(supportedDescription)"
      case .fileFailed(let operation, let url, let error):
        return
          "Audio file operation '\(operation)' failed for \(url?.lastPathComponent ?? "missing URL"): \(error)"
      case .captureSourceUnavailable(let details):
        return "The requested capture source is unavailable. \(details)"
      case .captureSourceFailed(let sourceDescription, let details):
        return "Capture source '\(sourceDescription)' failed. \(details)"
      case .coreAudioFailed(let operation, let osStatus, let details):
        return "Core Audio operation '\(operation)' failed (OSStatus \(osStatus)). \(details)"
      case .session(let sessionError):
        return sessionError.errorDescription
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
