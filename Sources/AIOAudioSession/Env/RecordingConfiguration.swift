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
  /// // Microphone (works on iOS and macOS). `.hardware` records at whatever
  /// // rate the route actually runs — no resampling; `.exact(.cd)` names a
  /// // target that AudioIO delivers by conversion when the route differs.
  /// let mic = RecordingConfiguration(
  ///   input: .microphone(MicrophoneRecordingInput(format: CaptureFormat(sampleRate: .hardware, channels: .mono))),
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
          MicrophoneRecordingInput(
            format: CaptureFormat(inputConfiguration),
            tapInterval: tapInterval,
          ),
        ),
        outputConfiguration: outputConfiguration,
        outputDestination: outputDestination,
      )
    }

    /// The requested capture format (sample-rate intent + channel count) for
    /// the selected source. Replaces the former exact-only `format`.
    public var requestedFormat: CaptureFormat { input.requestedFormat }

    /// The exact processing format, or `nil` while a
    /// ``RecordingSampleRate/hardware`` request has not been resolved against
    /// a live route.
    ///
    /// Everything that derives concrete formats — ``processingFormat``,
    /// `fileSettings`, the writer — reads this, so an unresolved configuration
    /// produces `nil` there exactly like an invalid one. Recording bring-up
    /// resolves via ``resolved(hardwareSampleRate:)`` before any of those are
    /// consulted.
    public var exactFormat: InputConfiguration? { requestedFormat.exactConfiguration }

    /// Whether recording bring-up must observe the route before this
    /// configuration has a concrete sample rate.
    package var requiresSampleRateResolution: Bool {
      requestedFormat.exactSampleRate == nil
    }

    /// Materializes an exact configuration from an observed hardware rate.
    ///
    /// ``RecordingSampleRate/exact(_:)`` requests return `self` unchanged.
    /// ``RecordingSampleRate/hardware`` adopts the observed rate when the
    /// output encoder can write it, otherwise the nearest encodable rate (the
    /// AAC family tops out at 48 kHz); the substitution is visible in the
    /// recording's ``ResolvedCaptureFormat``.
    package func resolved(hardwareSampleRate: SampleRate) -> RecordingConfiguration {
      resolvedWithSubstitution(hardwareSampleRate: hardwareSampleRate).configuration
    }

    /// ``resolved(hardwareSampleRate:)`` plus the substitution it made, if the
    /// adopted rate could not be carried as requested.
    package func resolvedWithSubstitution(
      hardwareSampleRate: SampleRate,
    ) -> (configuration: RecordingConfiguration, substitution: CaptureSubstitution?) {
      guard requiresSampleRateResolution else { return (self, nil) }
      return replacingSampleRate(with: .exact(hardwareSampleRate)).reducedToEncodable()
    }

    /// Reduces a self-contradictory request to one the encoder can write.
    ///
    /// A recording never refuses to start because its parts disagree. The
    /// least important axis yields first — channel layout › sample rate ›
    /// bit depth › container — so a 96 kHz request against an AAC output
    /// keeps its rate and is written as linear PCM in CAF. The one exception
    /// is a caller-named file (``OutputDestination/fileURL(_:)``): its
    /// container is already committed by name, so the rate yields to the
    /// nearest one the container supports instead. Either way the change is
    /// returned for the caller to present and record; nothing is silent.
    ///
    /// A ``RecordingSampleRate/hardware`` request has no rate to reduce yet
    /// and returns unchanged; bring-up resolves and then reduces it.
    public func reducedToEncodable() -> (
      configuration: RecordingConfiguration, substitution: CaptureSubstitution?
    ) {
      let fileFormat = outputConfiguration.fileFormat
      guard fileFormat == .aac || fileFormat == .adts,
        let rate = requestedFormat.exactSampleRate,
        !fileFormat.supports(sampleRate: rate)
      else {
        return (self, nil)
      }
      if case .fileURL = outputDestination {
        let clamped = fileFormat.nearestSupportedSampleRate(to: rate)
        return (
          replacingSampleRate(with: .exact(clamped)),
          .sampleRateClamped(from: rate, to: clamped, fileFormat: fileFormat)
        )
      }
      let replacement = OutputConfiguration(
        fileFormat: .caf,
        bitDepth: .pcmInt24,
        quality: outputConfiguration.quality,
      )
      return (
        RecordingConfiguration(
          input: input,
          outputConfiguration: replacement,
          outputDestination: outputDestination,
        ),
        .containerReplaced(from: fileFormat, to: .caf, sampleRate: rate)
      )
    }

    /// Rebuilds the configuration with a different sample-rate intent,
    /// preserving every source-specific option.
    private func replacingSampleRate(
      with sampleRate: RecordingSampleRate,
    ) -> RecordingConfiguration {
      let newInput: RecordingInput
      switch input {
      case .microphone(var microphone):
        microphone.format.sampleRate = sampleRate
        newInput = .microphone(microphone)
      #if os(macOS)
        case .systemAudio(var systemAudio):
          systemAudio.format.sampleRate = sampleRate
          newInput = .systemAudio(systemAudio)
      #endif
      }
      return RecordingConfiguration(
        input: newInput,
        outputConfiguration: outputConfiguration,
        outputDestination: outputDestination,
      )
    }

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
    ///
    /// A ``RecordingSampleRate/hardware`` request has no rate to check — it is
    /// resolved to an encodable rate at bring-up by construction — so only the
    /// output encoding and channel count are validated for it.
    public func validate() -> CaptureConfigurationValidation {
      if let exactFormat {
        return outputConfiguration.validate(against: exactFormat)
      }
      return outputConfiguration.validate(againstChannels: requestedFormat.channels)
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
        "\(fileFormat): \(requestedFormat.channels) \(requestedFormat.sampleRate), \(encoding.joined(separator: " ")) (destination: \(outputDestination))"
    }

    public var summary: String {
      let fileFormat = outputConfiguration.fileFormat.description
      let channels = requestedFormat.channels.description
      let sampleRate = requestedFormat.sampleRate.description
      return "\(fileFormat) • \(channels) • \(sampleRate)"
    }

    public var debugDescription: String {
      """
        fileFormat: \(outputConfiguration.fileFormat.description)
        sampleRate: \(requestedFormat.sampleRate)
        channels: \(requestedFormat.channels)
        bitDepth: \(outputConfiguration.bitDepth.map(String.init(describing:)) ?? "n/a")
        quality: \(outputConfiguration.fileFormat.usesEncodingQuality ? "\(outputConfiguration.quality)" : "n/a")
        outputDestination: \(outputDestination)
      """
    }

    /// Processing format for the audio engine pipeline.
    ///
    /// `nil` while a ``RecordingSampleRate/hardware`` request is unresolved —
    /// recording bring-up resolves before reading this.
    package var processingFormat: AVAudioFormat? {
      guard
        let exactFormat,
        let channelLayout = outputConfiguration.fileFormat.recordingChannelLayout(
          for: exactFormat.channels.count,
        )
      else {
        return nil
      }
      return AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: exactFormat.sampleRate.hz,
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
      exactFormat: InputConfiguration,
      bitDepth: Int,
      isFloat: Bool,
      isBigEndian: Bool,
      isInterleaved: Bool,
    ) -> AVAudioFormat? {
      AVAudioFormat(
        settings: makeLinearPCMSettings(
          exactFormat: exactFormat,
          bitDepth: bitDepth,
          isFloat: isFloat,
          isBigEndian: isBigEndian,
          isInterleaved: isInterleaved,
        ),
      )
    }

    private func makeLinearPCMSettings(
      exactFormat: InputConfiguration,
      bitDepth: Int,
      isFloat: Bool,
      isBigEndian: Bool,
      isInterleaved: Bool,
    ) -> [String: Any] {
      var settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: exactFormat.sampleRate.hz,
        AVNumberOfChannelsKey: exactFormat.channels.platform,
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
      let channelCount = requestedFormat.channels.count
      guard channelCount > 2 else { return nil }
      return outputConfiguration.fileFormat.recordingChannelLayoutData(for: channelCount)
    }

    /// Settings dictionary used to create the output `AVAudioFile`.
    ///
    /// This intentionally returns the original settings (not `AVAudioFormat.settings`), since
    /// `AVAudioFormat` may normalize/strip encoder-specific keys that must be preserved
    /// (example: `AVEncoderBitDepthHintKey`).
    package var fileSettings: [String: Any]? {
      guard let exactFormat, passesValidation() else { return nil }
      switch outputConfiguration.fileFormat {
      case .aac, .adts:
        // No bit-depth key: AAC is a transform codec with no PCM sample width
        // to declare. `AVEncoderAudioQualityKey` is the only encoding control
        // that reaches the file, which is what `usesEncodingQuality` reports
        // and `usesBitDepth` denies.
        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: exactFormat.sampleRate.hz,
          AVNumberOfChannelsKey: exactFormat.channels.platform,
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
          AVSampleRateKey: exactFormat.sampleRate.hz,
          AVNumberOfChannelsKey: exactFormat.channels.platform,
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
            exactFormat: exactFormat,
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
          exactFormat: exactFormat,
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
      guard let exactFormat, passesValidation() else { return nil }
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
              exactFormat: exactFormat,
              bitDepth: 24,
              isFloat: false,
              isBigEndian: false,
              isInterleaved: outputConfiguration.fileFormat == .wav ? true : false,
            )
          } else {
            outputConfiguration.fileFormat.recordingChannelLayout(
              for: exactFormat.channels.count,
            ).map {
              AVAudioFormat(
                commonFormat: commonFormat,
                sampleRate: exactFormat.sampleRate.hz,
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
          exactFormat: exactFormat,
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
        channelCount: requestedFormat.channels.count,
        inputFormat: input,
        outputFormat: fileFormat,
        tapReadSeconds: tapInterval.seconds,
      )
    }
  }
#endif
