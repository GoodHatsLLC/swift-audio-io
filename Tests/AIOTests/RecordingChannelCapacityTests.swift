// © GoodHatsLLC

#if canImport(AVFoundation)
  import Testing

  @testable import AIOAudioSession
  @_spi(TESTING) @testable import AIOEngine

  struct RecordingChannelCapacityTests {
    @Test
    @MainActor
    func `warming unsupported channel count emits typed error`() throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration(channels: .init(platform: 4))

      do {
        try engine.warm(configuration: configuration)
        Issue.record("Expected unsupportedRecordingChannelCount")
      } catch AIOEngine.AIOError.unsupportedRecordingChannelCount(
        let requested,
        let maximum
      ) {
        #expect(requested == 4)
        #expect(maximum == 2)
      } catch {
        Issue.record("Expected unsupportedRecordingChannelCount, got \(error)")
      }

      #expect(engine.isRecording == false)
    }

    @Test
    func `stereo buffer allocation remains unchanged`() {
      let engine = AIOEngine()

      let buffers = engine.makeAudioBuffers(sampleRate: 48_000, channelCount: 2)

      #expect(buffers.count == 2)
      #expect(buffers.allSatisfy { $0.capacity > 0 })
    }

    private func makeConfiguration(channels: ChannelCount) -> RecordingConfiguration {
      RecordingConfiguration(
        inputConfiguration: InputConfiguration(
          sampleRate: SampleRate.common(.sr48000),
          channels: channels,
        ),
        outputConfiguration: OutputConfiguration(
          fileFormat: .caf,
          bitDepth: .pcmFloat32,
          quality: .high,
        ),
      )
    }
  }
#endif
