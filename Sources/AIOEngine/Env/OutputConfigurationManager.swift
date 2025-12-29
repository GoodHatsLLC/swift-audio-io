import AVFAudio
import Observation

/// A class that manages the output configuration for audio recordings.
@MainActor
@Observable
public final class OutputConfigurationManager {

  let env: AudioEnvironment
  let errorManager: any ErrorManaging

  /// Creates a new `OutputConfigurationManager` instance.
  ///
  /// - Parameters:
  ///   - env: The audio environment to use.
  ///   - errorManager: The error manager to use for reporting errors.
  public init(
    env: AudioEnvironment,
    errorManager: any ErrorManaging
  ) {
    self.env = env
    self.errorManager = errorManager
  }

  /// The output file format for the recording.
  public var outputFormat: FileFormat? = .adts {
    didSet { alignBitDepthWithFormat() }
  }
  /// The available output file formats.
  public var availableOutputFormats: [FileFormat] {
    FileFormat.allCases
  }
  /// The bit depth for the recording.
  public var bitDepth: BitDepth? = .pcmFloat32
  /// The available bit depths for the selected file format.
  public var availableBitDepths: [BitDepth] {
    (outputFormat?.supportedBitDepths ?? BitDepth.allCases).sorted()
  }
  private var _encodingQuality: EncodingQuality? = .high

  /// The encoding quality for the recording.
  public var encodingQuality: EncodingQuality? {
    get {
      if let _encodingQuality {
        if availableEncodingQualities.contains(_encodingQuality) {
          _encodingQuality
        } else {
          availableEncodingQualities.first
        }
      } else {
        nil
      }
    }
    set {
      _encodingQuality = newValue
    }
  }

  /// The available encoding qualities for the selected file format.
  public var availableEncodingQualities: [EncodingQuality] {
    if outputFormat?.requiresQuality == true {
      EncodingQuality.allCases
    } else {
      [EncodingQuality.maximum]
    }
  }

  /// The current output configuration.
  public var outputConfiguration: OutputConfiguration? {
    guard
      let of = outputFormat ?? availableOutputFormats.first,
      let bd = bitDepth ?? availableBitDepths.first,
      let eq = encodingQuality ?? availableEncodingQualities.first
    else {
      return nil
    }

    return OutputConfiguration(fileFormat: of, bitDepth: bd, quality: eq)
  }

  private func alignBitDepthWithFormat() {
    guard let format = outputFormat else { return }

    if let bitDepth, !format.supportedBitDepths.contains(bitDepth) {
      self.bitDepth = format.supportedBitDepths.first
    } else if bitDepth == nil {
      self.bitDepth = format.supportedBitDepths.first
    }

    if format.requiresQuality == false {
      _encodingQuality = .maximum
    }
  }

}
