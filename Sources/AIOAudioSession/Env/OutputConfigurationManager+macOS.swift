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
      var bitDepthRawValue: Int
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

    public var availableBitDepths: [BitDepth] {
      (outputFormat?.supportedBitDepths ?? BitDepth.allCases).sorted()
    }

    public var encodingQuality: EncodingQuality? {
      didSet {
        persistToDefaultsIfNeeded()
      }
    }

    public var availableEncodingQualities: [EncodingQuality] {
      if outputFormat?.requiresQuality == true {
        EncodingQuality.allCases
      } else {
        [EncodingQuality.maximum]
      }
    }

    public var outputConfiguration: OutputConfiguration? {
      guard let format = outputFormat ?? availableOutputFormats.first,
        let depth = resolvedBitDepth(for: format) ?? format.supportedBitDepths.first,
        let quality = encodingQuality ?? availableEncodingQualities.first
      else {
        return nil
      }

      return OutputConfiguration(fileFormat: format, bitDepth: depth, quality: quality)
    }

    private func resolvedBitDepth(for fileFormat: FileFormat) -> BitDepth? {
      guard let bitDepth, fileFormat.supportedBitDepths.contains(bitDepth) else {
        return nil
      }
      return bitDepth
    }

    private func alignBitDepthWithFormat() {
      guard let format = outputFormat else { return }

      if let bitDepth, !format.supportedBitDepths.contains(bitDepth) {
        self.bitDepth = format.supportedBitDepths.first
      } else if bitDepth == nil {
        bitDepth = format.supportedBitDepths.first
      }

      if format.requiresQuality == false {
        encodingQuality = .maximum
      }
    }

    private func restoreFromDefaults() {
      if let persisted = readLastConfig() {
        outputFormat = FileFormat(rawValue: persisted.outputFormatRawValue)
        bitDepth = BitDepth(rawValue: persisted.bitDepthRawValue)
        encodingQuality = EncodingQuality(rawValue: persisted.encodingQualityRawValue)
      } else {
        outputFormat = .adts
        bitDepth = .pcmFloat32
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
        bitDepthRawValue: config.bitDepth.rawValue,
        encodingQualityRawValue: config.quality.rawValue,
      )

      guard let data = try? JSONEncoder().encode(persisted) else { return }
      defaults.set(data, forKey: StorageKey.lastConfig)
    }
  }
#endif
