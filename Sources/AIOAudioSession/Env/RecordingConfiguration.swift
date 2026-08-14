// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOSupport
  package import AVFoundation
  public import Foundation
  import os
  import Tools

  private let log = SystemLog.make()

  /// A complete description of a recording: its capture source, output encoding,
  /// and destination.
  ///
  /// The capture source is chosen with ``RecordingInput`` — ``MicrophoneRecordingInput``
  /// for the `AVAudioEngine` input tap, or (macOS) `SystemAudioRecordingInput` for a
  /// Core Audio process tap. Source-specific options live on the input case, so
  /// callers can only set options that apply to the selected source (for example
  /// `tapInterval` is microphone-only). The output encoding (``OutputConfiguration``)
  /// and `outputDestination` are source-agnostic.
  ///
  /// ```swift
  /// // Microphone (works on iOS and macOS):
  /// let mic = RecordingConfiguration(
  ///   input: .microphone(MicrophoneRecordingInput(format: InputConfiguration(sampleRate: .cd, channels: .mono))),
  ///   outputConfiguration: OutputConfiguration(fileFormat: .caf, bitDepth: .pcmFloat32, quality: .maximum))
  /// ```
  ///
  /// Microphone capture is available on iOS and macOS; system-audio capture is
  /// macOS-only.
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

    /// Creates a source-specific recording configuration.
    ///
    /// - Parameters:
    ///   - input: The capture source and its source-specific options.
    ///   - outputConfiguration: The output file format, bit depth, and quality.
    ///   - outputDestination: Where to write the file — a temporary file, a
    ///     directory, or an explicit file URL. Defaults to `.temporary`.
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

    /// Whether this configuration can be written as described, checked without
    /// touching an audio session.
    ///
    /// The capture format and the output encoding are chosen independently, so
    /// this is where the pair is checked: a 96 kHz microphone request and an
    /// `m4a` output are each individually reasonable and jointly impossible.
    /// ``fileSettings`` and the writer both refuse an invalid configuration, so
    /// calling this first turns a silent `nil` into a nameable reason.
    public func validate() -> CaptureConfigurationValidation {
      outputConfiguration.validate(against: format)
    }

    public var description: String {
      let fileFormat = outputConfiguration.fileFormat
      var encoding: [String] = []
      if let bitDepth = outputConfiguration.bitDepth {
        encoding.append("\(bitDepth)")
      }
      if fileFormat.usesEncodingQuality {
        encoding.append("\(outputConfiguration.quality)")
      }
      return
        "\(fileFormat): \(format.channels) \(format.sampleRate), \(encoding.joined(separator: " ")) (destination: \(outputDestination))"
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
        bitDepth: \(outputConfiguration.bitDepth.map(String.init(describing:)) ?? "n/a")
        quality: \(outputConfiguration.fileFormat.usesEncodingQuality ? "\(outputConfiguration.quality)" : "n/a")
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

    /// The `AVAudioCommonFormat` for the configured PCM sample width.
    ///
    /// Only reached on the PCM container paths, which validation guarantees
    /// carry a bit depth; the `nil` arm keeps the mapping total.
    var commonFormat: AVAudioCommonFormat {
      switch outputConfiguration.bitDepth {
      case .pcmInt16: .pcmFormatInt16
      case .pcmInt24: .pcmFormatInt32
      case .pcmFloat32, .none: .pcmFormatFloat32
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

    /// The single gate both ``fileSettings`` and ``fileFormat`` pass through.
    ///
    /// The sample-rate, channel-count, and bit-depth checks used to be
    /// duplicated inline per format arm, some of them twice in the same
    /// property. They now live in ``validate()``, which callers can also run
    /// themselves without producing a format.
    private func passesValidation() -> Bool {
      let validation = validate()
      guard validation.isValid else {
        log.error(
          "invalid capture configuration: \(validation.description, privacy: .public)",
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
      guard passesValidation() else { return nil }
      switch outputConfiguration.fileFormat {
      case .aac, .adts:
        // No bit-depth key: AAC is a transform codec with no PCM sample width
        // to declare. `AVEncoderAudioQualityKey` is the only encoding control
        // that reaches the file, which is what `usesEncodingQuality` reports
        // and `usesBitDepth` denies.
        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: format.sampleRate.hz,
          AVNumberOfChannelsKey: format.channels.platform,
          AVEncoderAudioQualityKey: Int(outputConfiguration.quality.avAudio.rawValue),
        ]
        var settingsWithLayout = settings
        if let channelLayout = multichannelLayoutDataForFileSettings {
          settingsWithLayout[AVChannelLayoutKey] = channelLayout
        }
        guard AVAudioFormat(settings: settingsWithLayout) != nil else { return nil }
        return settingsWithLayout

      case .flac:
        guard let bitDepth = outputConfiguration.bitDepth else { return nil }
        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatFLAC,
          AVSampleRateKey: format.sampleRate.hz,
          AVNumberOfChannelsKey: format.channels.platform,
          AVEncoderBitDepthHintKey: bitDepth.rawValue,
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
          case .pcmFloat32, .none: (32, true)
          }

        return makeLinearPCMSettings(
          bitDepth: bitDepth,
          isFloat: isFloat,
          isBigEndian: true,
          isInterleaved: true,
        )
      }
    }

    /// Output format for file writing.
    ///
    /// Sample-rate and channel-count admissibility is decided once, by
    /// ``validate()``, rather than re-derived per format arm — the AAC arm used
    /// to run the same sample-rate check twice, and the PCM and FLAC arms
    /// carried their own hard-coded bounds that could drift from
    /// ``FileFormat/supportsEncodedSampleRate(_:)``.
    var fileFormat: AVAudioFormat? {
      guard passesValidation() else { return nil }
      switch outputConfiguration.fileFormat {
      case .aac, .adts, .flac:
        guard let settings = fileSettings,
          let format = AVAudioFormat(settings: settings)
        else {
          log.error(
            "could not make format for \(outputConfiguration.fileFormat.description, privacy: .public) settings",
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

        guard let validFormat = format else {
          log.error("invalid pcm format: \(format, privacy: .public)")
          return nil
        }
        log.info("using valid format: \(validFormat, privacy: .public)")
        return validFormat

      case .aiff:
        let (bitDepth, isFloat) =
          switch outputConfiguration.bitDepth {
          case .pcmInt16: (16, false)
          case .pcmInt24: (24, false)
          case .pcmFloat32, .none: (32, true)
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
