// © GoodHatsLLC

#if os(macOS)
  public import Foundation
  public import Observation

  @MainActor
  @Observable
  public final class OutputConfigurationManager {
    private let defaults: UserDefaults

    private struct PersistedOutputConfiguration: Codable {
      var outputFormatRawValue: String
      /// Absent for formats with no selectable bit depth — the AAC family. A
      /// value persisted by an older build simply fails to match the format's
      /// supported depths on restore and is dropped.
      var bitDepthRawValue: Int?
      var encodingQualityRawValue: Int
    }

    private enum StorageKey {
      static let lastConfig = "aio.output_config.last.v1"
    }

    public init(
      env: AudioEnvironment,
      errorManager: any ErrorManaging,
      defaults: UserDefaults = UserDefaults(),
    ) {
      _ = env
      _ = errorManager
      self.defaults = defaults
      restoreFromDefaults()
    }

    public func withPersistenceSuspended<T>(_ work: () throws -> T) rethrows -> T {
      try work()
    }

    public var outputFormat: FileFormat? {
      didSet {
        alignBitDepthWithFormat()
        persistToDefaultsIfNeeded()
      }
    }

    public var availableOutputFormats: [FileFormat] {
      FileFormat.allCases
    }

    public var bitDepth: BitDepth? {
      didSet {
        persistToDefaultsIfNeeded()
      }
    }

    /// The bit depths the selected file format's writer can actually use.
    ///
    /// Empty when the format has none to choose — the AAC family — in which
    /// case ``bitDepth`` is `nil` and a UI should show no control.
    public var availableBitDepths: [BitDepth] {
      (outputFormat?.supportedBitDepths ?? BitDepth.allCases).sorted()
    }

    /// Whether the selected file format uses a bit depth at all.
    public var usesBitDepth: Bool {
      outputFormat?.usesBitDepth ?? true
    }

    public var encodingQuality: EncodingQuality? {
      didSet {
        persistToDefaultsIfNeeded()
      }
    }

    public var availableEncodingQualities: [EncodingQuality] {
      if outputFormat?.usesEncodingQuality == true {
        EncodingQuality.allCases
      } else {
        [EncodingQuality.maximum]
      }
    }

    /// Whether the selected file format's writer uses the encoding quality.
    public var usesEncodingQuality: Bool {
      outputFormat?.usesEncodingQuality ?? false
    }

    /// The current output configuration.
    ///
    /// The bit depth is `nil` — legitimately, not for want of a value — when
    /// the selected format has none to choose.
    public var outputConfiguration: OutputConfiguration? {
      guard let format = outputFormat ?? availableOutputFormats.first,
        let quality = encodingQuality ?? availableEncodingQualities.first
      else {
        return nil
      }
      let depth = resolvedBitDepth(for: format) ?? format.defaultBitDepth
      guard depth != nil || !format.usesBitDepth else { return nil }

      return OutputConfiguration(fileFormat: format, bitDepth: depth, quality: quality)
    }

    /// Validates the current selection against the format a capture will
    /// deliver, without touching the audio session.
    public func validate(
      against inputFormat: InputConfiguration,
    ) -> CaptureConfigurationValidation {
      guard let outputConfiguration else { return .valid }
      return outputConfiguration.validate(against: inputFormat)
    }

    /// The output formats whose writer can encode the given capture format.
    public func availableOutputFormats(
      for inputFormat: InputConfiguration,
    ) -> [FileFormat] {
      availableOutputFormats.filter { fileFormat in
        fileFormat.supports(sampleRate: inputFormat.sampleRate)
          && fileFormat.supportsRecordingChannelCount(inputFormat.channels.count)
      }
    }

    private func resolvedBitDepth(for fileFormat: FileFormat) -> BitDepth? {
      guard let bitDepth, fileFormat.supportedBitDepths.contains(bitDepth) else {
        return nil
      }
      return bitDepth
    }

    private func alignBitDepthWithFormat() {
      guard let format = outputFormat else { return }

      // `defaultBitDepth` is `nil` for formats with no selectable depth, which
      // is the value those formats must carry — not a failure to resolve one.
      if let bitDepth, !format.supportedBitDepths.contains(bitDepth) {
        self.bitDepth = format.defaultBitDepth
      } else if bitDepth == nil, format.usesBitDepth {
        bitDepth = format.defaultBitDepth
      }

      if format.usesEncodingQuality == false {
        encodingQuality = .maximum
      }
    }

    private func restoreFromDefaults() {
      if let persisted = readLastConfig() {
        outputFormat = FileFormat(rawValue: persisted.outputFormatRawValue)
        bitDepth = persisted.bitDepthRawValue.flatMap(BitDepth.init(rawValue:))
        encodingQuality = EncodingQuality(rawValue: persisted.encodingQualityRawValue)
      } else {
        // ADTS has no selectable bit depth, so the default carries none.
        outputFormat = .adts
        bitDepth = nil
        encodingQuality = .high
      }

      alignBitDepthWithFormat()
    }

    private func readLastConfig() -> PersistedOutputConfiguration? {
      guard let data = defaults.data(forKey: StorageKey.lastConfig) else { return nil }
      return try? JSONDecoder().decode(PersistedOutputConfiguration.self, from: data)
    }

    private func persistToDefaultsIfNeeded() {
      guard let config = outputConfiguration else { return }

      let persisted = PersistedOutputConfiguration(
        outputFormatRawValue: config.fileFormat.rawValue,
        bitDepthRawValue: config.bitDepth?.rawValue,
        encodingQualityRawValue: config.quality.rawValue,
      )

      guard let data = try? JSONEncoder().encode(persisted) else { return }
      defaults.set(data, forKey: StorageKey.lastConfig)
    }
  }
#endif
