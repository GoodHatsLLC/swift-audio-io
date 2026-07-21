// © GoodHatsLLC

#if os(iOS)
  import Foundation
  import Testing
  @testable import AIOAudioSession

  @Suite("AudioEnvironmentPreferenceStore")
  @MainActor
  struct AudioEnvironmentPreferenceStoreTests {
    private func makeIsolatedDefaults() throws -> UserDefaults {
      let suiteName = "aio.tests.audio-environment-preferences.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defaults.removePersistentDomain(forName: suiteName)
      return defaults
    }

    @Test
    func `input configuration updates do not create an explicit input preference`() throws {
      let store = AudioEnvironmentPreferenceStore(defaults: try makeIsolatedDefaults())

      store.update(
        inputId: "airpods",
        currentSampleRate: .dvd,
        isConfiguredForStereo: false,
        currentSourceId: nil,
      ) { preferences in
        preferences.sampleRateHz = SampleRate.cd.hz
      }

      #expect(store.preferredInputId == nil)
      #expect(store.hasPreferences(for: "airpods"))

      store.setPreferredInputId("built-in")
      #expect(store.preferredInputId == "built-in")

      store.setPreferredInputId(nil)
      #expect(store.preferredInputId == nil)
    }

    @Test
    func `measurement preference remains isolated to the injected domain`() throws {
      let first = AudioEnvironmentPreferenceStore(defaults: try makeIsolatedDefaults())
      let second = AudioEnvironmentPreferenceStore(defaults: try makeIsolatedDefaults())

      first.setUseMeasurement(true)

      #expect(first.useMeasurement)
      #expect(!second.useMeasurement)
    }
  }
#endif
