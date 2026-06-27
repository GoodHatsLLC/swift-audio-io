// © GoodHatsLLC

/// A stable, sendable snapshot of a selectable audio input endpoint.
///
/// ``AudioInput`` itself is backed by platform objects on iOS. Recording
/// configurations carry this lightweight value instead, then resolve it against
/// the live platform route immediately before capture starts.
public struct AudioInputSelection: Hashable, Sendable, Identifiable, CustomStringConvertible {
  public let id: String
  public let name: String
  public let type: AudioInput.InputType
  public let channelCount: ChannelCount

  public init(
    id: String,
    name: String,
    type: AudioInput.InputType = .unknown,
    channelCount: ChannelCount = .mono,
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.channelCount = channelCount
  }

  public init(input: AudioInput) {
    self.init(
      id: input.id,
      name: input.name,
      type: input.type,
      channelCount: input.channelCount,
    )
  }

  public var description: String {
    name
  }
}

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

  /// Preferred physical/logical input endpoint to record from. If `nil`,
  /// AudioIO uses the platform's current/default input route.
  public var preferredInput: AudioInputSelection?

  /// - Parameters:
  ///   - format: The requested sample rate + channel count.
  ///   - tapInterval: The input-node tap delivery cadence. Defaults to 100 ms.
  ///   - preferredInput: Optional input endpoint to select before recording.
  public init(
    format: InputConfiguration,
    tapInterval: Duration = .seconds(0.1),
    preferredInput: AudioInputSelection? = nil,
  ) {
    self.format = format
    self.tapInterval = tapInterval
    self.preferredInput = preferredInput
  }
}
