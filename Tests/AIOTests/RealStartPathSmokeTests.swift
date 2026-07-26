// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOTestSupport
  import AVFoundation
  import Foundation
  import Testing

  @testable import AudioIO

  @Suite("Real start path — smoke")
  struct RealStartPathSmokeTests {
    private func makeConfiguration() -> RecordingConfiguration {
      RecordingConfiguration(
        inputConfiguration: InputConfiguration(sampleRate: .dvd, channels: .mono),
        outputConfiguration: OutputConfiguration(
          fileFormat: .caf,
          bitDepth: .pcmFloat32,
          quality: .high,
        ),
      )
    }

    @Test("startRecording drives the real lifecycle with fake hardware")
    @MainActor
    func realStartPath() async throws {
      let (engine, backend, tapInstaller) = AIOEngine.fakeRecording()
      let configuration = makeConfiguration()

      let url = try await engine.startRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      #expect(engine.isRecording)
      #expect(backend.startCalls == 1)
      #expect(tapInstaller.installCount() == 1)

      backend.inject(channels: [[Float](repeating: 0.25, count: 1_024)])

      let stopped = try await engine.stopRecording()
      #expect(stopped == url)
      #expect(!engine.isRecording)
    }
  }
#endif
