// © GoodHatsLLC

#if canImport(AVFoundation)
  import Atomics
  import Observation
  import Testing
  @testable import AudioIO

  struct RecordingLifecycleObservationTests {
    @MainActor
    @Test
    func `recording state remains observable through the engine facade`() {
      let engine = AIOEngine()
      let didChange = ManagedAtomic(false)

      withObservationTracking {
        _ = engine.isRecording
      } onChange: {
        didChange.store(true, ordering: .relaxed)
      }

      engine.isRecording = true

      let observationFired = didChange.load(ordering: .relaxed)
      #expect(observationFired)
      #expect(engine.isRecording)
    }
  }
#endif
