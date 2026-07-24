// © GoodHatsLLC

#if canImport(UIKit)
  import AVFoundation
  import Foundation
  import Testing

  @testable import AIOAudioSession
  @_spi(TESTING) @testable import AudioIO
  @testable import AIORecording
  @testable import AIORecordingSupport

  /// Exercises the audio-session interruption **resume decision** for recording in
  /// isolation from the real audio engine.
  ///
  /// `.interruptionBegan` routes through graceful stop, whose real
  /// `AVAudioEngine` teardown crashes the iOS Simulator audio HAL. The
  /// `debugBypassEngineTeardownForTesting()` seam replaces only that teardown, so
  /// the staging/`.shouldResume`-gating logic runs end-to-end headlessly. These
  /// tests live in their own suite so the simulator crash in sibling
  /// `AIOEngineIntegrationTests` cannot abort the process and mask them.
  @MainActor
  struct AIOEngineInterruptionResumeTests {
    @Test
    func `interruption resumes recording when shouldResume is set`() async throws {
      let engine = AIOEngine()
      engine.debugBypassEngineTeardownForTesting()
      let readiness = CountingRecordingStartReadiness()
      engine.setRecordingStartReadinessForTesting(readiness)

      let url = try engine.startTestRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }

      // `.began` tears down recording but stages the configuration for resume.
      await engine.handleAudioSystemEvent(.interruptionBegan)
      #expect(engine.isRecording == false)

      // `.ended` with `.shouldResume` re-enters the canonical awaited start path.
      await engine.handleAudioSystemEvent(.interruptionEnded(shouldResume: true))
      #expect(await readiness.attemptCount() == 1)
    }

    @Test
    func `interruption does not resume recording without shouldResume`() async throws {
      let engine = AIOEngine()
      engine.debugBypassEngineTeardownForTesting()
      let readiness = CountingRecordingStartReadiness()
      engine.setRecordingStartReadinessForTesting(readiness)

      let url = try engine.startTestRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }

      await engine.handleAudioSystemEvent(.interruptionBegan)
      #expect(engine.isRecording == false)

      // `.ended` without `.shouldResume` (cases the system deems unsafe to resume,
      // e.g. some Siri/route-loss endings) must leave recording stopped.
      await engine.handleAudioSystemEvent(.interruptionEnded(shouldResume: false))
      #expect(engine.isRecording == false)
      #expect(await readiness.attemptCount() == 0)
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

  private actor CountingRecordingStartReadiness: RecordingStartReadiness {
    private var count = 0

    func attempt(
      configuration _: RecordingConfiguration,
    ) async throws(RecordingError) -> URL {
      count += 1
      return FileManager.default.temporaryDirectory
        .appendingPathComponent("interruption-resume-\(UUID().uuidString).caf")
    }

    func attemptCount() -> Int {
      count
    }
  }
#endif
