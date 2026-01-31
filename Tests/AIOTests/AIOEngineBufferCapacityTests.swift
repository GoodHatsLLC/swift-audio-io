#if canImport(UIKit)
  import Foundation
  import Testing

  @_spi(TESTING) import AIOEngine

  @Suite
  struct AIOEngineBufferCapacityTests {
    @Test
    func testMonoBufferCapacityMatchesTwoSeconds() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration(channels: .mono)

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      let capacities = engine.debugBufferCapacities()
      let expected = expectedCapacity(sampleRate: 48_000, seconds: 2.0)

      #expect(capacities.writer.count == 1)
      #expect(capacities.receiver.count == 1)
      #expect(capacities.writer.first == expected)
      #expect(capacities.receiver.first == expected)

      _ = try await engine.stopRecording()
    }

    @Test
    func testStereoBufferCapacityMatchesTwoSeconds() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration(channels: .stereo)

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      let capacities = engine.debugBufferCapacities()
      let expected = expectedCapacity(sampleRate: 48_000, seconds: 2.0)

      #expect(capacities.writer.count == 2)
      #expect(capacities.receiver.count == 2)
      #expect(capacities.writer.allSatisfy { $0 == expected })
      #expect(capacities.receiver.allSatisfy { $0 == expected })

      _ = try await engine.stopRecording()
    }

    private func makeConfiguration(channels: ChannelCount) -> RecordingConfiguration {
      let input = InputConfiguration(
        sampleRate: SampleRate.common(.sr48000),
        channels: channels
      )
      let output = OutputConfiguration(
        fileFormat: .caf,
        bitDepth: .pcmFloat32,
        quality: .high
      )
      return RecordingConfiguration(
        inputConfiguration: input,
        outputConfiguration: output,
        outputDestination: .temporary
      )
    }

    private func expectedCapacity(sampleRate: Int, seconds: Double) -> Int {
      let raw = max(1, Int(Double(sampleRate) * seconds))
      var power = 1
      while power < raw {
        power *= 2
      }
      return power
    }
  }
#endif
