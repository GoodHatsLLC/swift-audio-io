#if canImport(AVFoundation)
  import AVFoundation
  import Foundation
  import SystemLog

  private let log = SystemLog.make()

  public struct RecordingConfiguration: CustomStringConvertible, CustomDebugStringConvertible,
    Hashable, Identifiable, Sendable
  {

    #if os(iOS)
      public enum OutputDestination: Hashable, Sendable, CustomStringConvertible {
        case temporary
        case directory(URL, fileProtection: FileProtectionType? = nil)
        case fileURL(URL, fileProtection: FileProtectionType? = nil)

        public var description: String {
          switch self {
          case .temporary:
            return "temporary"
          case .directory(let url, let protection):
            return "directory(\(url.path), protection=\(String(describing: protection)))"
          case .fileURL(let url, let protection):
            return "fileURL(\(url.path), protection=\(String(describing: protection)))"
          }
        }
      }
    #else
      public enum OutputDestination: Hashable, Sendable, CustomStringConvertible {
        case temporary
        case directory(URL)
        case fileURL(URL)

        public var description: String {
          switch self {
          case .temporary:
            return "temporary"
          case .directory(let url):
            return "directory(\(url.path))"
          case .fileURL(let url):
            return "fileURL(\(url.path))"
          }
        }
      }
    #endif

    public var id: Self { self }
    public let inputConfiguration: InputConfiguration
    public let outputConfiguration: OutputConfiguration
    public let tapInterval: Duration
    public let outputDestination: OutputDestination

    public init(
      inputConfiguration: InputConfiguration,
      outputConfiguration: OutputConfiguration,
      tapInterval: Duration = .seconds(0.1),
      outputDestination: OutputDestination = .temporary
    ) {
      self.inputConfiguration = inputConfiguration
      self.outputConfiguration = outputConfiguration
      self.tapInterval = tapInterval
      self.outputDestination = outputDestination
    }

    public var description: String {
      "\(outputConfiguration.fileFormat): \(inputConfiguration.channels) \(inputConfiguration.sampleRate), \(outputConfiguration.bitDepth) \(outputConfiguration.fileFormat.requiresQuality ? "\(outputConfiguration.quality)" : "") (destination: \(outputDestination))"
    }

    public var summary: String {
      let format = outputConfiguration.fileFormat.description
      let channels = inputConfiguration.channels.description
      let sampleRate = inputConfiguration.sampleRate.description
      return "\(format) • \(channels) • \(sampleRate)"
    }

    public var debugDescription: String {
      """
        fileFormat: \(fileFormat?.description ?? "nil")
        sampleRate: \(inputConfiguration.sampleRate)
        channels: \(inputConfiguration.channels)
        bitDepth: \(outputConfiguration.bitDepth)
        quality: \(outputConfiguration.quality)
        outputDestination: \(outputDestination)
      """
    }

    // Processing format for the audio engine pipeline.
    var processingFormat: AVAudioFormat? {
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: inputConfiguration.sampleRate.platform,
        channels: inputConfiguration.channels.platform,
        interleaved: false
      )
    }

    var commonFormat: AVAudioCommonFormat {
      switch outputConfiguration.bitDepth {
      case .pcmInt16: .pcmFormatInt16
      case .pcmInt24: .pcmFormatInt32
      case .pcmFloat32: .pcmFormatFloat32
      }
    }

    private func makeLinearPCMFormat(
      bitDepth: Int,
      isFloat: Bool,
      isBigEndian: Bool,
      isInterleaved: Bool
    ) -> AVAudioFormat? {
      AVAudioFormat(
        settings: makeLinearPCMSettings(
          bitDepth: bitDepth,
          isFloat: isFloat,
          isBigEndian: isBigEndian,
          isInterleaved: isInterleaved
        )
      )
    }

    private func makeLinearPCMSettings(
      bitDepth: Int,
      isFloat: Bool,
      isBigEndian: Bool,
      isInterleaved: Bool
    ) -> [String: Any] {
      [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: inputConfiguration.sampleRate.rawValue,
        AVNumberOfChannelsKey: inputConfiguration.channels.platform,
        AVLinearPCMBitDepthKey: bitDepth,
        AVLinearPCMIsFloatKey: isFloat,
        AVLinearPCMIsBigEndianKey: isBigEndian,
        AVLinearPCMIsNonInterleaved: !isInterleaved,
      ]
    }

    /// Settings dictionary used to create the output `AVAudioFile`.
    ///
    /// This intentionally returns the original settings (not `AVAudioFormat.settings`), since
    /// `AVAudioFormat` may normalize/strip encoder-specific keys that must be preserved
    /// (example: `AVEncoderBitDepthHintKey`).
    var fileSettings: [String: Any]? {
      switch outputConfiguration.fileFormat {
      case .aac, .adts:
        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: inputConfiguration.sampleRate.rawValue,
          AVNumberOfChannelsKey: inputConfiguration.channels.platform,
          AVEncoderAudioQualityKey: outputConfiguration.quality.platform,
        ]
        guard AVAudioFormat(settings: settings) != nil else { return nil }
        return settings

      case .flac:
        let encoderBitDepthHint: Int =
          switch outputConfiguration.bitDepth {
          case .pcmInt16: 16
          case .pcmInt24: 24
          case .pcmFloat32: 16
          }

        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatFLAC,
          AVSampleRateKey: inputConfiguration.sampleRate.rawValue,
          AVNumberOfChannelsKey: inputConfiguration.channels.platform,
          AVEncoderBitDepthHintKey: encoderBitDepthHint,
        ]
        guard AVAudioFormat(settings: settings) != nil else { return nil }
        return settings

      case .wav, .caf:
        if outputConfiguration.bitDepth == .pcmInt24 {
          return makeLinearPCMSettings(
            bitDepth: 24,
            isFloat: false,
            isBigEndian: false,
            isInterleaved: outputConfiguration.fileFormat == .wav ? true : false
          )
        }
        return fileFormat?.settings

      case .aiff:
        let (bitDepth, isFloat): (Int, Bool) =
          switch outputConfiguration.bitDepth {
          case .pcmInt16: (16, false)
          case .pcmInt24: (24, false)
          case .pcmFloat32: (32, true)
          }

        return makeLinearPCMSettings(
          bitDepth: bitDepth,
          isFloat: isFloat,
          isBigEndian: true,
          isInterleaved: true
        )
      }
    }

    /// Output format for file writing
    var fileFormat: AVAudioFormat? {
      switch outputConfiguration.fileFormat {
      case .aac, .adts:
        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: inputConfiguration.sampleRate.rawValue,
          AVNumberOfChannelsKey: inputConfiguration.channels.platform,
          AVEncoderAudioQualityKey: outputConfiguration.quality.platform,
        ]

        // Validate AAC format settings before creating
        guard let format = AVAudioFormat(settings: settings) else {
          log.error("could not make format for settings: \(settings, privacy: .public)")
          return nil
        }

        // Additional validation for AAC compatibility
        let sampleRate = inputConfiguration.sampleRate.rawValue
        let channelCount = inputConfiguration.channels.platform

        // AAC supports limited sample rates and channel configurations
        let validSampleRates: [Double] = [
          8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200, 96000,
        ]
        guard validSampleRates.contains(sampleRate) else {
          log.error("invalid sample rate: \(sampleRate, privacy: .public)")
          return nil
        }

        // AAC supports up to 48 channels, but commonly used configurations are safer
        guard channelCount <= 8 else {
          log.error("invalid channel count: \(channelCount, privacy: .public)")
          return nil
        }

        return format

      case .flac:
        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatFLAC,
          AVSampleRateKey: inputConfiguration.sampleRate.rawValue,
          AVNumberOfChannelsKey: inputConfiguration.channels.platform,
          AVEncoderBitDepthHintKey: fileSettings?[AVEncoderBitDepthHintKey] ?? 16,
        ]

        // Validate FLAC format settings before creating
        guard let format = AVAudioFormat(settings: settings) else {
          log.error("could not make format for settings: \(settings, privacy: .public)")
          return nil
        }

        // FLAC validation
        let sampleRate = inputConfiguration.sampleRate.rawValue
        let channelCount = inputConfiguration.channels.platform

        // FLAC supports wide range of sample rates
        guard sampleRate <= 655350,  // FLAC max sample rate
          channelCount <= 8,  // FLAC supports up to 8 channels
          sampleRate >= 8000  // Reasonable minimum
        else {
          log.error(
            "invalid FLAC configuration: \(sampleRate, privacy: .public)Hz, \(channelCount, privacy: .public)ch"
          )
          return nil
        }

        return format

      case .wav, .caf:
        let format: AVAudioFormat?
        if outputConfiguration.bitDepth == .pcmInt24 {
          // 24-bit PCM should be truly packed 24-bit container samples, not 32-bit container
          // samples created via the .pcmFormatInt32 fallback.
          format = makeLinearPCMFormat(
            bitDepth: 24,
            isFloat: false,
            isBigEndian: false,
            isInterleaved: outputConfiguration.fileFormat == .wav ? true : false
          )
        } else {
          format = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: inputConfiguration.sampleRate.rawValue,
            channels: inputConfiguration.channels.platform,
            interleaved: outputConfiguration.fileFormat.requiresInterleaved
          )
        }

        // Validate PCM format constraints
        guard let validFormat = format else {
          log.error("invalid pcm format: \(format, privacy: .public)")
          return nil
        }

        // Additional validation for extreme configurations
        let sampleRate = inputConfiguration.sampleRate.rawValue
        let channelCount = inputConfiguration.channels.platform

        // Check for reasonable limits
        guard sampleRate <= 192000,  // 192kHz max
          channelCount <= 32,  // 32 channels max
          sampleRate >= 8000  // 8kHz min
        else {
          log.error("unreasonable sample rate: \(sampleRate, privacy: .public)")
          return nil
        }

        log.info("using valid format: \(validFormat, privacy: .public)")
        return validFormat

      case .aiff:
        let (bitDepth, isFloat): (Int, Bool) =
          switch outputConfiguration.bitDepth {
          case .pcmInt16: (16, false)
          case .pcmInt24: (24, false)
          case .pcmFloat32: (32, true)
          }

        let format = makeLinearPCMFormat(
          bitDepth: bitDepth,
          isFloat: isFloat,
          isBigEndian: true,
          isInterleaved: true
        )

        guard let validFormat = format else {
          log.error("invalid aiff format: \(format, privacy: .public)")
          return nil
        }

        log.info("using valid format: \(validFormat, privacy: .public)")
        return validFormat
      }
    }

    public var fileExtension: String {
      outputConfiguration.fileFormat.fileExtension
    }

    func tapConfiguration(bus: Int = 0, input: AVAudioFormat) -> TapConfiguration? {
      guard let fileFormat else { return nil }
      return .init(
        bus: bus,
        channelCount: inputConfiguration.channels.count,
        inputFormat: input,
        outputFormat: fileFormat,
        tapReadSeconds: tapInterval.seconds
      )
    }

  }
#endif
