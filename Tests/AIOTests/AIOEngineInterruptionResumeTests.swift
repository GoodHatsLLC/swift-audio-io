// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOTestSupport
  import AVFoundation
  import Foundation
  import Testing

  @testable import AIOAudioSession
  @testable import AIORecording
  @testable import AIORecordingSupport
  import AudioIO

  /// Exercises the audio-session interruption **resume decision** for recording.
  ///
  /// Both the initial start and the resume run the real
  /// `RecordingLifecycle.attemptRecordingStart`; only the tap install, engine
  /// start, and graph teardown are faked. A resume is therefore observable as a
  /// second `start()` on the capture backend.
  @MainActor
  struct AIOEngineInterruptionResumeTests {
    @Test
    func `interruption resumes recording when shouldResume is set`() async throws {
      let (engine, backend, _) = AIOEngine.fakeRecording()

      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }
      #expect(backend.startCalls == 1)

      // `.began` tears down recording but stages the configuration for resume.
      await engine.handleAudioSystemEvent(.interruptionBegan)
      #expect(engine.isRecording == false)

      // `.ended` with `.shouldResume` re-enters the canonical awaited start path.
      await engine.handleAudioSystemEvent(.interruptionEnded(shouldResume: true))
      #expect(backend.startCalls == 2)
      #expect(engine.isRecording)
    }

    @Test
    func `interruption does not resume recording without shouldResume`() async throws {
      let (engine, backend, _) = AIOEngine.fakeRecording()

      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }
      #expect(backend.startCalls == 1)

      await engine.handleAudioSystemEvent(.interruptionBegan)
      #expect(engine.isRecording == false)

      // `.ended` without `.shouldResume` (cases the system deems unsafe to resume,
      // e.g. some Siri/route-loss endings) must leave recording stopped.
      await engine.handleAudioSystemEvent(.interruptionEnded(shouldResume: false))
      #expect(engine.isRecording == false)
      #expect(backend.startCalls == 1)
    }

    private func makeConfiguration() -> RecordingConfiguration {
      let input = InputConfiguration(
        sampleRate: .dvd,
        channels: .mono,
      )
      let output = OutputConfiguration(
        fileFormat: .caf,
        bitDepth: .pcmFloat32,
        quality: .high,
      )
      return RecordingConfiguration(
        inputConfiguration: input,
        outputConfiguration: output,
        outputDestination: .temporary,
      )
    }
  }
#endif
