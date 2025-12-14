#if canImport(AVFoundation)
  import AVFoundation
  import Foundation
  import SystemLog

  private let log = SystemLog.make()

  public struct RecordingConfiguration: CustomStringConvertible, CustomDebugStringConvertible,
    Hashable, Identifiable, Sendable
  {

    public var id: Self { self }
    public let inputConfiguration: InputConfiguration
    public let outputConfiguration: OutputConfiguration
    public let tapInterval: Duration

    public init(
      inputConfiguration: InputConfiguration,
      outputConfiguration: OutputConfiguration,
      tapInterval: Duration = .seconds(0.1)
    ) {
      self.inputConfiguration = inputConfiguration
      self.outputConfiguration = outputConfiguration
      self.tapInterval = tapInterval
    }

    public var description: String {
      "\(outputConfiguration.fileFormat): \(inputConfiguration.channels) \(inputConfiguration.sampleRate), \(outputConfiguration.bitDepth) \(outputConfiguration.fileFormat.requiresConversion ? "\(outputConfiguration.quality)" : "")"
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
      case .pcm16: .pcmFormatInt16
      case .pcm24: .pcmFormatInt32
      case .pcmFloat32: .pcmFormatFloat32
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
          AVEncoderAudioQualityKey: outputConfiguration.quality.platform,
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
        let format = AVAudioFormat(
          commonFormat: commonFormat,
          sampleRate: inputConfiguration.sampleRate.rawValue,
          channels: inputConfiguration.channels.platform,
          interleaved: outputConfiguration.fileFormat.requiresInterleaved
        )

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
