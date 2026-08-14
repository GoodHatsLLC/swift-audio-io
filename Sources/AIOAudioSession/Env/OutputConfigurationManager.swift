// © GoodHatsLLC

#if os(iOS)
  import AVFAudio
  public import Foundation
  public import Observation

  /// A class that manages the output configuration for audio recordings.
  @MainActor
  @Observable
  public final class OutputConfigurationManager {
    let env: AudioEnvironment
    let errorManager: any ErrorManaging
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
      static let configByInputId = "aio.output_config.by_input_id.v1"
    }

    private var cachedInputId: String?
    private var isRestoringFromDefaults: Bool = false
    private var persistenceSuspensionDepth: Int = 0

    private var isPersistenceSuspended: Bool {
      persistenceSuspensionDepth > 0
    }

    /// Creates a new `OutputConfigurationManager` instance.
    ///
    /// - Parameters:
    ///   - env: The audio environment to use.
    ///   - errorManager: The error manager to use for reporting errors.
    public init(
      env: AudioEnvironment,
      errorManager: any ErrorManaging,
      defaults: UserDefaults = UserDefaults(),
    ) {
      self.env = env
      self.errorManager = errorManager
      self.defaults = defaults
      restoreFromDefaultsForCurrentInputIfNeeded()
    }

    /// Performs the given work without persisting configuration changes.
    public func withPersistenceSuspended<T>(_ work: () throws -> T) rethrows -> T {
      persistenceSuspensionDepth += 1
      defer { persistenceSuspensionDepth -= 1 }
      return try work()
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
    /// The bit depths the selected file format's writer can actually use.
    ///
    /// Empty when the format has none to choose — the AAC family — in which
    /// case ``bitDepth`` is `nil` and a UI should show no control. This used to
    /// report two depths for AAC that changed nothing about the file.
    public var availableBitDepths: [BitDepth] {
      (outputFormat?.supportedBitDepths ?? BitDepth.allCases).sorted()
    }

    /// Whether the selected file format uses a bit depth at all.
    public var usesBitDepth: Bool {
      outputFormat?.usesBitDepth ?? true
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
    ///
    /// A single fixed value for formats whose writer ignores quality, so a UI
    /// binding stays total without implying a choice exists.
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
      restoreFromDefaultsForCurrentInputIfNeeded()
      guard let of = outputFormat ?? availableOutputFormats.first,
        let eq = encodingQuality ?? availableEncodingQualities.first
      else {
        return nil
      }
      let bd = resolveBitDepth(for: of) ?? of.defaultBitDepth
      guard bd != nil || !of.usesBitDepth else { return nil }

      return OutputConfiguration(fileFormat: of, bitDepth: bd, quality: eq)
    }

    /// Validates the current selection against the format a capture will
    /// deliver, without touching the audio session.
    ///
    /// The output selection is stored per input device while the requested
    /// input sample rate is a single global intent, so the two can drift into a
    /// combination neither side rejected on its own — a 96 kHz request against
    /// a remembered `m4a` output, say. This is how a caller finds out before
    /// activation rather than at the writer.
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

    private func resolveBitDepth(for fileFormat: FileFormat) -> BitDepth? {
      if let bd = bitDepth, fileFormat.supportedBitDepths.contains(bd) {
        return bd
      }
      return nil
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
        _bitDepth = config.bitDepthRawValue.flatMap(BitDepth.init(rawValue:))
        _encodingQuality = EncodingQuality(rawValue: config.encodingQualityRawValue)
      } else {
        // ADTS has no selectable bit depth, so the default carries none.
        _outputFormat = .adts
        _bitDepth = nil
        _encodingQuality = .high
      }

      alignBitDepthWithFormat()
    }

    private func persistToDefaultsIfNeeded() {
      guard !isRestoringFromDefaults else { return }
      guard !isPersistenceSuspended else { return }
      guard let config = outputConfiguration else { return }

      let persisted = PersistedOutputConfiguration(
        outputFormatRawValue: config.fileFormat.rawValue,
        bitDepthRawValue: config.bitDepth?.rawValue,
        encodingQualityRawValue: config.quality.rawValue,
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
        let dict = try? JSONDecoder().decode(
          [String: PersistedOutputConfiguration].self, from: data,
        )
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
