// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOTestSupport
  import Foundation
  import Testing
  @testable import AIOAudioSession
  import AudioIO
  import Tools

  /// Coverage for the first-buffer host-time anchor surfaced via
  /// ``AIOEngine/recordingTimingSnapshot()`` for cross-device alignment.
  struct RecordingTimingSnapshotTests {
    @Test
    func `snapshot is nil before any host-timed buffer is captured`() async throws {
      let (engine, _, _) = AIOEngine.fakeRecording()
      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }

      #expect(await engine.recordingTimingSnapshot() == nil)

      _ = try await engine.stopRecording()
    }

    @Test
    func `snapshot anchors the first host-timed buffer`() async throws {
      let (engine, backend, _) = AIOEngine.fakeRecording()
      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }

      backend.inject(
        channels: [ramp(count: 64)],
        hostTime: 12_345_678,
        sourceSampleTime: 9_000,
      )

      let snapshot = try #require(await engine.recordingTimingSnapshot())
      #expect(snapshot.firstBufferHostTime == 12_345_678)
      #expect(snapshot.firstBufferSampleTime == 9_000)
      #expect(snapshot.lastBufferHostTime == 12_345_678)
      #expect(snapshot.capturedFrameCount == 64)
      #expect(snapshot.hostTimeSpanFrameCount == 0)

      _ = try await engine.stopRecording()
    }

    @Test
    func `snapshot keeps the FIRST host time when later buffers arrive`() async throws {
      let (engine, backend, _) = AIOEngine.fakeRecording()
      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }

      backend.inject(channels: [ramp(count: 32)], hostTime: 1_000, sourceSampleTime: 10)
      backend.inject(channels: [ramp(count: 32)], hostTime: 2_000, sourceSampleTime: 20)

      let snapshot = try #require(await engine.recordingTimingSnapshot())
      #expect(snapshot.firstBufferHostTime == 1_000)
      #expect(snapshot.firstBufferSampleTime == 10)
      #expect(snapshot.lastBufferHostTime == 2_000)
      #expect(snapshot.capturedFrameCount == 64)
      #expect(snapshot.hostTimeSpanFrameCount == 32)

      _ = try await engine.stopRecording()
    }

    @Test
    func `snapshot persists after stopRecording`() async throws {
      let (engine, backend, _) = AIOEngine.fakeRecording()
      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }

      backend.inject(channels: [ramp(count: 64)], hostTime: 7_777, sourceSampleTime: 42)
      _ = try await engine.stopRecording()

      let snapshot = try #require(await engine.recordingTimingSnapshot())
      #expect(snapshot.firstBufferHostTime == 7_777)
      #expect(snapshot.firstBufferSampleTime == 42)
      #expect(snapshot.lastBufferHostTime == 7_777)
      #expect(snapshot.capturedFrameCount == 64)
      #expect(snapshot.hostTimeSpanFrameCount == 0)
    }

    @Test
    func `buffers without a valid host time do not anchor`() async throws {
      let (engine, backend, _) = AIOEngine.fakeRecording()
      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }

      // A buffer with no host time leaves the anchor unset...
      backend.inject(channels: [ramp(count: 32)], hostTime: nil)
      #expect(await engine.recordingTimingSnapshot() == nil)

      // ...and the next buffer that *does* carry a host time becomes the anchor.
      backend.inject(channels: [ramp(count: 32)], hostTime: 555, sourceSampleTime: nil)
      let snapshot = try #require(await engine.recordingTimingSnapshot())
      #expect(snapshot.firstBufferHostTime == 555)
      #expect(snapshot.firstBufferSampleTime == nil)
      #expect(snapshot.lastBufferHostTime == 555)
      #expect(snapshot.capturedFrameCount == 64)
      #expect(snapshot.hostTimeSpanFrameCount == 0)

      _ = try await engine.stopRecording()
    }

    @Test
    func `host time span excludes persisted frames before the first host-timed buffer`()
      async throws
    {
      let (engine, backend, _) = AIOEngine.fakeRecording()
      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }

      backend.inject(channels: [ramp(count: 16)], hostTime: nil)
      backend.inject(channels: [ramp(count: 32)], hostTime: 1_000)
      backend.inject(channels: [ramp(count: 64)], hostTime: 2_000)
      backend.inject(channels: [ramp(count: 8)], hostTime: nil)

      let snapshot = try #require(await engine.recordingTimingSnapshot())
      #expect(snapshot.firstBufferHostTime == 1_000)
      #expect(snapshot.lastBufferHostTime == 2_000)
      #expect(snapshot.capturedFrameCount == 120)
      #expect(snapshot.hostTimeSpanFrameCount == 32)

      _ = try await engine.stopRecording()
    }

    private func makeConfiguration() -> RecordingConfiguration {
      let input = InputConfiguration(sampleRate: .dvd, channels: .mono)
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

    private func ramp(count: Int) -> [Float] {
      guard count > 0 else { return [] }
      return (0..<count).map { Float($0) / Float(count) }
    }
  }
#endif
