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
  /// `handleInterruption(.began)` routes through `gracefulStop()`, whose real
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

      let url = try await engine.startTestRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }

      // `.began` tears down recording but stages the configuration for resume.
      await engine.handleInterruption(type: .began, options: nil)
      #expect(engine.isRecording == false)
      #expect(engine.wantsRecording == false)

      // `.ended` with `.shouldResume` re-arms the desired-recording state via the
      // same reconciliation path media-services recovery uses.
      await engine.handleInterruption(type: .ended, options: [.shouldResume])
      #expect(engine.wantsRecording == true)

      // Halt the resume reconciliation so it does not drive the real engine.
      engine.setDesiredRecordingState(false, configuration: nil)
    }

    @Test
    func `interruption does not resume recording without shouldResume`() async throws {
      let engine = AIOEngine()
      engine.debugBypassEngineTeardownForTesting()

      let url = try await engine.startTestRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }

      await engine.handleInterruption(type: .began, options: nil)
      #expect(engine.isRecording == false)

      // `.ended` without `.shouldResume` (cases the system deems unsafe to resume,
      // e.g. some Siri/route-loss endings) must leave recording stopped.
      await engine.handleInterruption(type: .ended, options: [])
      #expect(engine.wantsRecording == false)
      #expect(engine.isRecording == false)
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
