// © GoodHatsLLC

#if os(macOS)
  import Testing

  @testable import AIOAudioSession
  @testable import AudioIO

  struct SystemAudioStartTests {
    // The mono/stereo constraint is enforced before any HAL object is created, so
    // this is deterministic without system-audio permission. (The happy-path tap
    // lifecycle requires NSAudioCaptureUsageDescription + TCC and is validated
    // on-device.)
    @MainActor
    @Test
    func `system audio rejects more than two channels before touching the HAL`() async {
      let engine = AIOEngine()
      let configuration = RecordingConfiguration(
        input: .systemAudio(
          SystemAudioRecordingInput(
            format: CaptureFormat(sampleRate: .exact(.dvd), channels: .init(platform: 6)),
          ),
        ),
        outputConfiguration: OutputConfiguration(
          fileFormat: .caf,
          bitDepth: .pcmFloat32,
          quality: .high,
        ),
      )

      do {
        _ = try await engine.startRecording(configuration: configuration)
        Issue.record("expected unsupportedChannelCount")
      } catch RecordingError.unsupportedChannelCount(let requested, let maximum) {
        #expect(requested == 6)
        #expect(maximum == 2)
      } catch {
        Issue.record("unexpected error: \(error)")
      }
    }
  }
#endif
