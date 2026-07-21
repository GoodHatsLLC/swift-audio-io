// © GoodHatsLLC

#if os(iOS)
  import Foundation

  @MainActor
  final class AudioEnvironmentPreferenceStore {
    struct InputPreferences: Codable {
      var sampleRateHz: Double?
      var channelCount: Int?
      var sourceId: String?
      var rejectedSampleRatesHz: [Double]?
    }

    private enum StorageKey {
      static let preferredInputId = "aio.audio_env.explicit_preferred_input_id.v2"
      static let inputPrefsById = "aio.audio_env.input_prefs_by_id.v1"
      static let useMeasurement = "aio.audio_env.use_measurement"
    }

    private let defaults: UserDefaults
    private var inputPreferencesById: [String: InputPreferences]

    init(defaults: UserDefaults) {
      self.defaults = defaults
      inputPreferencesById = Self.loadInputPreferences(from: defaults)
    }

    var useMeasurement: Bool {
      defaults.bool(forKey: StorageKey.useMeasurement)
    }

    func setUseMeasurement(_ useMeasurement: Bool) {
      defaults.set(useMeasurement, forKey: StorageKey.useMeasurement)
    }

    var preferredInputId: String? {
      defaults.string(forKey: StorageKey.preferredInputId)
    }

    func setPreferredInputId(_ inputId: String?) {
      if let inputId {
        defaults.set(inputId, forKey: StorageKey.preferredInputId)
      } else {
        defaults.removeObject(forKey: StorageKey.preferredInputId)
      }
    }

    func hasPreferences(for inputId: String) -> Bool {
      inputPreferencesById[inputId] != nil
    }

    func preferences(for inputId: String) -> InputPreferences? {
      inputPreferencesById[inputId]
    }

    func reload() {
      inputPreferencesById = Self.loadInputPreferences(from: defaults)
    }

    func update(
      inputId: String,
      currentSampleRate: SampleRate,
      isConfiguredForStereo: Bool,
      currentSourceId: String?,
      _ update: (inout InputPreferences) -> Void,
    ) {
      var prefs =
        inputPreferencesById[inputId]
        ?? InputPreferences(
          sampleRateHz: currentSampleRate.hz,
          channelCount: isConfiguredForStereo ? 2 : 1,
          sourceId: currentSourceId,
        )
      update(&prefs)

      inputPreferencesById[inputId] = prefs
      guard let data = try? JSONEncoder().encode(inputPreferencesById) else { return }
      defaults.set(data, forKey: StorageKey.inputPrefsById)
    }

    private static func loadInputPreferences(
      from defaults: UserDefaults,
    ) -> [String: InputPreferences] {
      guard let data = defaults.data(forKey: StorageKey.inputPrefsById) else { return [:] }
      return (try? JSONDecoder().decode([String: InputPreferences].self, from: data))
        ?? [:]
    }
  }
#endif
