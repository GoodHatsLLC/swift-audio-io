// © GoodHatsLLC

/// The capture source for a recording, with source-specific options.
///
/// Modeled as an enum so callers can only provide options that make sense for
/// the selected source — for example `tapInterval` is microphone-only and is
/// not reachable for system audio.
public enum RecordingInput: Hashable, Sendable {
  case microphone(MicrophoneRecordingInput)
  #if os(macOS)
    case systemAudio(SystemAudioRecordingInput)
  #endif

  /// The requested processing format (sample rate + channel count), common to
  /// every source. The file/encoder pipeline reads this rather than unwrapping
  /// the source-specific case.
  public var format: InputConfiguration {
    switch self {
    case .microphone(let microphone): microphone.format
    #if os(macOS)
      case .systemAudio(let systemAudio): systemAudio.format
    #endif
    }
  }
}

/// Microphone capture options (the `AVAudioEngine` input-node tap path).
public struct MicrophoneRecordingInput: Hashable, Sendable {
  /// The requested processing format (sample rate + channel count).
  public var format: InputConfiguration

  /// The cadence at which the input-node tap delivers buffers to the pipeline.
  ///
  /// This is an `AVAudioEngine` input-node concept and has no system-audio
  /// equivalent — HAL IO cadence is chosen by the hardware, not the caller.
  public var tapInterval: Duration

  /// - Parameters:
  ///   - format: The requested sample rate + channel count.
  ///   - tapInterval: The input-node tap delivery cadence. Defaults to 100 ms.
  public init(format: InputConfiguration, tapInterval: Duration = .seconds(0.1)) {
    self.format = format
    self.tapInterval = tapInterval
  }
}
