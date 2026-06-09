// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOSupport
  package import AVFoundation
  public import Foundation
  import os
  import Tools

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
            "temporary"
          case .directory(let url, let protection):
            "directory(\(url.path), protection=\(String(describing: protection)))"
          case .fileURL(let url, let protection):
            "fileURL(\(url.path), protection=\(String(describing: protection)))"
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
            "temporary"
          case .directory(let url):
            "directory(\(url.path))"
          case .fileURL(let url):
            "fileURL(\(url.path))"
          }
        }
      }
    #endif

    public var id: Self {
      self
    }

    public let input: RecordingInput
    public let outputConfiguration: OutputConfiguration
    public let outputDestination: OutputDestination

    public init(
      input: RecordingInput,
      outputConfiguration: OutputConfiguration,
      outputDestination: OutputDestination = .temporary,
    ) {
      self.input = input
      self.outputConfiguration = outputConfiguration
      self.outputDestination = outputDestination
    }

    /// Migration convenience: builds a microphone-source configuration. Prefer
    /// the source-specific `init(input:outputConfiguration:outputDestination:)`
    /// for new code.
    public init(
      inputConfiguration: InputConfiguration,
      outputConfiguration: OutputConfiguration,
      tapInterval: Duration = .seconds(0.1),
      outputDestination: OutputDestination = .temporary,
    ) {
      self.init(
        input: .microphone(
          MicrophoneRecordingInput(format: inputConfiguration, tapInterval: tapInterval),
        ),
        outputConfiguration: outputConfiguration,
        outputDestination: outputDestination,
      )
    }

    /// The requested processing format (sample rate + channel count) for the
    /// selected source. Replaces the former stored `inputConfiguration`.
    public var format: InputConfiguration { input.format }

    /// Microphone input-node tap cadence. Package-internal: the value lives on
    /// `MicrophoneRecordingInput`; system audio has no tap interval, so the
    /// system-audio path never consults this.
    package var tapInterval: Duration {
      switch input {
      case .microphone(let microphone): microphone.tapInterval
      #if os(macOS)
        // System audio has no tap interval; the system-audio path never consults
        // this. Return the default so the microphone tap machinery stays total.
        case .systemAudio: .seconds(0.1)
      #endif
      }
    }

    public var description: String {
      let fileFormat = outputConfiguration.fileFormat
      return
        "\(fileFormat): \(format.channels) \(format.sampleRate), \(outputConfiguration.bitDepth) \(fileFormat.requiresQuality ? "\(outputConfiguration.quality)" : "") (destination: \(outputDestination))"
    }

    public var summary: String {
      let fileFormat = outputConfiguration.fileFormat.description
      let channels = format.channels.description
      let sampleRate = format.sampleRate.description
      return "\(fileFormat) • \(channels) • \(sampleRate)"
    }

    public var debugDescription: String {
      """
        fileFormat: \(outputConfiguration.fileFormat.description)
        sampleRate: \(format.sampleRate)
        channels: \(format.channels)
        bitDepth: \(outputConfiguration.bitDepth)
        quality: \(outputConfiguration.quality)
        outputDestination: \(outputDestination)
      """
    }

    /// Processing format for the audio engine pipeline.
    package var processingFormat: AVAudioFormat? {
      guard
        let channelLayout = outputConfiguration.fileFormat.recordingChannelLayout(
          for: format.channels.count,
        )
      else {
        return nil
      }
      return AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: format.sampleRate.hz,
        interleaved: false,
        channelLayout: channelLayout,
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
      isInterleaved: Bool,
    ) -> AVAudioFormat? {
      AVAudioFormat(
        settings: makeLinearPCMSettings(
          bitDepth: bitDepth,
          isFloat: isFloat,
          isBigEndian: isBigEndian,
          isInterleaved: isInterleaved,
        ),
      )
    }

    private func makeLinearPCMSettings(
      bitDepth: Int,
      isFloat: Bool,
      isBigEndian: Bool,
      isInterleaved: Bool,
    ) -> [String: Any] {
      var settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: format.sampleRate.hz,
        AVNumberOfChannelsKey: format.channels.platform,
        AVLinearPCMBitDepthKey: bitDepth,
        AVLinearPCMIsFloatKey: isFloat,
        AVLinearPCMIsBigEndianKey: isBigEndian,
        AVLinearPCMIsNonInterleaved: !isInterleaved,
      ]
      if let channelLayout = multichannelLayoutDataForFileSettings {
        settings[AVChannelLayoutKey] = channelLayout
      }
      return settings
    }

    private func validatesRecordingChannelCount() -> Bool {
      let fileFormat = outputConfiguration.fileFormat
      let channelCount = format.channels.count
      guard fileFormat.supportsRecordingChannelCount(channelCount) else {
        log.error(
          "invalid \(fileFormat.description, privacy: .public) channel count: \(channelCount, privacy: .public)",
        )
        return false
      }
      return true
    }

    private var multichannelLayoutDataForFileSettings: Data? {
      let channelCount = format.channels.count
      guard channelCount > 2 else { return nil }
      return outputConfiguration.fileFormat.recordingChannelLayoutData(for: channelCount)
    }

    /// Settings dictionary used to create the output `AVAudioFile`.
    ///
    /// This intentionally returns the original settings (not `AVAudioFormat.settings`), since
    /// `AVAudioFormat` may normalize/strip encoder-specific keys that must be preserved
    /// (example: `AVEncoderBitDepthHintKey`).
    package var fileSettings: [String: Any]? {
      guard validatesRecordingChannelCount() else { return nil }
      switch outputConfiguration.fileFormat {
      case .aac, .adts:
        let sampleRate = format.sampleRate.hz
        guard outputConfiguration.fileFormat.supportsEncodedSampleRate(sampleRate) else {
          log.error("invalid sample rate: \(sampleRate, privacy: .public)")
          return nil
        }
        let qualityRawValue = Int(outputConfiguration.quality.avAudio.rawValue)
        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: sampleRate,
          AVNumberOfChannelsKey: format.channels.platform,
          AVEncoderAudioQualityKey: qualityRawValue,
        ]
        var settingsWithLayout = settings
        if let channelLayout = multichannelLayoutDataForFileSettings {
          settingsWithLayout[AVChannelLayoutKey] = channelLayout
        }
        guard AVAudioFormat(settings: settingsWithLayout) != nil else { return nil }
        return settingsWithLayout

      case .flac:
        let encoderBitDepthHint =
          switch outputConfiguration.bitDepth {
          case .pcmInt16: 16
          case .pcmInt24: 24
          case .pcmFloat32: 16
          }

        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatFLAC,
          AVSampleRateKey: format.sampleRate.hz,
          AVNumberOfChannelsKey: format.channels.platform,
          AVEncoderBitDepthHintKey: encoderBitDepthHint,
        ]
        var settingsWithLayout = settings
        if let channelLayout = multichannelLayoutDataForFileSettings {
          settingsWithLayout[AVChannelLayoutKey] = channelLayout
        }
        guard AVAudioFormat(settings: settingsWithLayout) != nil else { return nil }
        return settingsWithLayout

      case .wav, .caf:
        if outputConfiguration.bitDepth == .pcmInt24 {
          return makeLinearPCMSettings(
            bitDepth: 24,
            isFloat: false,
            isBigEndian: false,
            isInterleaved: outputConfiguration.fileFormat == .wav ? true : false,
          )
        }
        return fileFormat?.settings

      case .aiff:
        let (bitDepth, isFloat) =
          switch outputConfiguration.bitDepth {
          case .pcmInt16: (16, false)
          case .pcmInt24: (24, false)
          case .pcmFloat32: (32, true)
          }

        return makeLinearPCMSettings(
          bitDepth: bitDepth,
          isFloat: isFloat,
          isBigEndian: true,
          isInterleaved: true,
        )
      }
    }

    /// Output format for file writing
    var fileFormat: AVAudioFormat? {
      guard validatesRecordingChannelCount() else { return nil }
      switch outputConfiguration.fileFormat {
      case .aac, .adts:
        let sampleRate = format.sampleRate.hz
        guard outputConfiguration.fileFormat.supportsEncodedSampleRate(sampleRate) else {
          log.error("invalid sample rate: \(sampleRate, privacy: .public)")
          return nil
        }
        let qualityRawValue = Int(outputConfiguration.quality.avAudio.rawValue)
        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: sampleRate,
          AVNumberOfChannelsKey: format.channels.platform,
          AVEncoderAudioQualityKey: qualityRawValue,
        ]
        var settingsWithLayout = settings
        if let channelLayout = multichannelLayoutDataForFileSettings {
          settingsWithLayout[AVChannelLayoutKey] = channelLayout
        }

        // Validate AAC format settings before creating
        guard let format = AVAudioFormat(settings: settingsWithLayout) else {
          log.error("could not make format for settings: \(settingsWithLayout, privacy: .public)")
          return nil
        }

        // AAC supports limited sample rates and channel configurations
        guard outputConfiguration.fileFormat.supportsEncodedSampleRate(sampleRate) else {
          log.error("invalid sample rate: \(sampleRate, privacy: .public)")
          return nil
        }

        return format

      case .flac:
        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatFLAC,
          AVSampleRateKey: format.sampleRate.hz,
          AVNumberOfChannelsKey: format.channels.platform,
          AVEncoderBitDepthHintKey: fileSettings?[AVEncoderBitDepthHintKey] ?? 16,
        ]
        var settingsWithLayout = settings
        if let channelLayout = multichannelLayoutDataForFileSettings {
          settingsWithLayout[AVChannelLayoutKey] = channelLayout
        }

        // Validate FLAC format settings before creating
        guard let format = AVAudioFormat(settings: settingsWithLayout) else {
          log.error("could not make format for settings: \(settingsWithLayout, privacy: .public)")
          return nil
        }

        // FLAC validation
        let sampleRate = input.format.sampleRate.hz

        // FLAC supports wide range of sample rates
        guard sampleRate <= 655_350,  // FLAC max sample rate
          sampleRate >= 8000  // Reasonable minimum
        else {
          log.error(
            "invalid FLAC configuration: \(sampleRate, privacy: .public)Hz, \(input.format.channels.count, privacy: .public)ch",
          )
          return nil
        }

        return format

      case .wav, .caf:
        let format: AVAudioFormat? =
          if outputConfiguration.bitDepth == .pcmInt24 {
            // 24-bit PCM should be truly packed 24-bit container samples, not 32-bit container
            // samples created via the .pcmFormatInt32 fallback.
            makeLinearPCMFormat(
              bitDepth: 24,
              isFloat: false,
              isBigEndian: false,
              isInterleaved: outputConfiguration.fileFormat == .wav ? true : false,
            )
          } else {
            outputConfiguration.fileFormat.recordingChannelLayout(
              for: input.format.channels.count,
            ).map {
              AVAudioFormat(
                commonFormat: commonFormat,
                sampleRate: input.format.sampleRate.hz,
                interleaved: outputConfiguration.fileFormat.requiresInterleaved,
                channelLayout: $0,
              )
            }
          }

        // Validate PCM format constraints
        guard let validFormat = format else {
          log.error("invalid pcm format: \(format, privacy: .public)")
          return nil
        }

        // Additional validation for extreme configurations
        let sampleRate = input.format.sampleRate.hz

        // Check for reasonable limits
        guard sampleRate <= 192_000,  // 192kHz max
          sampleRate >= 8000  // 8kHz min
        else {
          log.error("unreasonable sample rate: \(sampleRate, privacy: .public)")
          return nil
        }

        log.info("using valid format: \(validFormat, privacy: .public)")
        return validFormat

      case .aiff:
        let (bitDepth, isFloat) =
          switch outputConfiguration.bitDepth {
          case .pcmInt16: (16, false)
          case .pcmInt24: (24, false)
          case .pcmFloat32: (32, true)
          }

        let format = makeLinearPCMFormat(
          bitDepth: bitDepth,
          isFloat: isFloat,
          isBigEndian: true,
          isInterleaved: true,
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

    package func tapConfiguration(bus: Int = 0, input: AVAudioFormat) -> TapConfiguration? {
      guard let fileFormat else { return nil }
      return .init(
        bus: bus,
        channelCount: format.channels.count,
        inputFormat: input,
        outputFormat: fileFormat,
        tapReadSeconds: tapInterval.seconds,
      )
    }
  }
#endif
