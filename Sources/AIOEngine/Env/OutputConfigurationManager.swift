#if canImport(AVFoundation) && (!os(macOS) || targetEnvironment(macCatalyst))
import AVFAudio
import Foundation
import Observation

/// A class that manages the output configuration for audio recordings.
@MainActor
@Observable
public final class OutputConfigurationManager {

  let env: AudioEnvironment
  let errorManager: any ErrorManaging
  private let defaults: UserDefaults

  private struct PersistedOutputConfiguration: Codable, Sendable {
    var outputFormatRawValue: String
    var bitDepthRawValue: Int
    var encodingQualityRawValue: Int
  }

  private enum StorageKey {
    static let lastConfig = "aio.output_config.last.v1"
    static let configByInputId = "aio.output_config.by_input_id.v1"
  }

  private var cachedInputId: String?
  private var isRestoringFromDefaults: Bool = false

  /// Creates a new `OutputConfigurationManager` instance.
  ///
  /// - Parameters:
  ///   - env: The audio environment to use.
  ///   - errorManager: The error manager to use for reporting errors.
  public init(
    env: AudioEnvironment,
    errorManager: any ErrorManaging,
    defaults: UserDefaults = .standard
  ) {
    self.env = env
    self.errorManager = errorManager
    self.defaults = defaults
    restoreFromDefaultsForCurrentInputIfNeeded()
  }

  /// The output file format for the recording.
  public var outputFormat: FileFormat? {
    get {
      restoreFromDefaultsForCurrentInputIfNeeded()
      return _outputFormat
    }
    set {
      restoreFromDefaultsForCurrentInputIfNeeded()
      _outputFormat = newValue
      alignBitDepthWithFormat()
      persistToDefaultsIfNeeded()
    }
  }
  private var _outputFormat: FileFormat? = .adts
  /// The available output file formats.
  public var availableOutputFormats: [FileFormat] {
    FileFormat.allCases
  }
  /// The bit depth for the recording.
  public var bitDepth: BitDepth? {
    get {
      restoreFromDefaultsForCurrentInputIfNeeded()
      return _bitDepth
    }
    set {
      restoreFromDefaultsForCurrentInputIfNeeded()
      _bitDepth = newValue
      persistToDefaultsIfNeeded()
    }
  }
  private var _bitDepth: BitDepth? = .pcmFloat32
  /// The available bit depths for the selected file format.
  public var availableBitDepths: [BitDepth] {
    (outputFormat?.supportedBitDepths ?? BitDepth.allCases).sorted()
  }
  private var _encodingQuality: EncodingQuality? = .high

  /// The encoding quality for the recording.
  public var encodingQuality: EncodingQuality? {
    get {
      restoreFromDefaultsForCurrentInputIfNeeded()
      guard let stored = _encodingQuality else { return nil }
      if availableEncodingQualities.contains(stored) { return stored }
      return availableEncodingQualities.first
    }
    set {
      restoreFromDefaultsForCurrentInputIfNeeded()
      _encodingQuality = newValue
      persistToDefaultsIfNeeded()
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
    restoreFromDefaultsForCurrentInputIfNeeded()
    guard
      let of = outputFormat ?? availableOutputFormats.first,
      let bd = resolveBitDepth(for: of) ?? of.supportedBitDepths.first,
      let eq = encodingQuality ?? availableEncodingQualities.first
    else {
      return nil
    }

    return OutputConfiguration(fileFormat: of, bitDepth: bd, quality: eq)
  }

  private func resolveBitDepth(for fileFormat: FileFormat) -> BitDepth? {
    if let bd = bitDepth, fileFormat.supportedBitDepths.contains(bd) {
      return bd
    }
    return nil
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

  private func currentInputId() -> String {
    env.input?.id ?? "_default"
  }

  private func restoreFromDefaultsForCurrentInputIfNeeded() {
    let inputId = currentInputId()
    guard cachedInputId != inputId else { return }
    cachedInputId = inputId

    isRestoringFromDefaults = true
    defer { isRestoringFromDefaults = false }

    if let config = readConfig(forInputId: inputId) ?? readLastConfig() {
      _outputFormat = FileFormat(rawValue: config.outputFormatRawValue)
      _bitDepth = BitDepth(rawValue: config.bitDepthRawValue)
      _encodingQuality = EncodingQuality(rawValue: config.encodingQualityRawValue)
    } else {
      _outputFormat = .adts
      _bitDepth = .pcmFloat32
      _encodingQuality = .high
    }

    alignBitDepthWithFormat()
  }

  private func persistToDefaultsIfNeeded() {
    guard !isRestoringFromDefaults else { return }
    guard let config = outputConfiguration else { return }

    let persisted = PersistedOutputConfiguration(
      outputFormatRawValue: config.fileFormat.rawValue,
      bitDepthRawValue: config.bitDepth.rawValue,
      encodingQualityRawValue: config.quality.rawValue
    )

    writeLastConfig(persisted)
    writeConfig(persisted, forInputId: currentInputId())
  }

  private func readLastConfig() -> PersistedOutputConfiguration? {
    guard let data = defaults.data(forKey: StorageKey.lastConfig) else { return nil }
    return try? JSONDecoder().decode(PersistedOutputConfiguration.self, from: data)
  }

  private func writeLastConfig(_ config: PersistedOutputConfiguration) {
    guard let data = try? JSONEncoder().encode(config) else { return }
    defaults.set(data, forKey: StorageKey.lastConfig)
  }

  private func readConfig(forInputId inputId: String) -> PersistedOutputConfiguration? {
    guard let data = defaults.data(forKey: StorageKey.configByInputId) else { return nil }
    guard
      let dict = try? JSONDecoder().decode([String: PersistedOutputConfiguration].self, from: data)
    else { return nil }
    return dict[inputId]
  }

  private func writeConfig(_ config: PersistedOutputConfiguration, forInputId inputId: String) {
    let existingData = defaults.data(forKey: StorageKey.configByInputId)
    var dict: [String: PersistedOutputConfiguration] =
      (existingData.flatMap {
        try? JSONDecoder().decode([String: PersistedOutputConfiguration].self, from: $0)
      })
      ?? [:]

    dict[inputId] = config

    guard let data = try? JSONEncoder().encode(dict) else { return }
    defaults.set(data, forKey: StorageKey.configByInputId)
  }

}
#endif
