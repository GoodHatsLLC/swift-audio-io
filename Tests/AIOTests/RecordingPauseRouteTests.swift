// © GoodHatsLLC

#if canImport(AVFoundation)
  @testable import AIOEngineCore
  import AIOTestSupport
  import AVFoundation
  import Foundation
  import Testing

  @testable import AIOAudioSession
  import AudioIO

  /// A route that cannot feed the tap pauses the recording; a route that can
  /// resumes it. Neither is a stop.
  @MainActor
  struct RecordingPauseRouteTests {
    @Test
    func `losing every input pauses and a returning input resumes`() async throws {
      let (engine, _, tapInstaller) = AIOEngine.fakeRecording()
      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }
      let installsAfterStart = tapInstaller.installCount()

      await engine.handleAudioSystemEvent(.routeChanged(routeChange(inputAvailable: false)))
      #expect(engine.isRecording)
      guard case .sourceUnavailable = engine.recordingPause?.reason else {
        Issue.record(
          "Expected a source-unavailable pause, got \(String(describing: engine.recordingPause))",
        )
        return
      }
      #expect(tapInstaller.installCount() == installsAfterStart)

      await engine.handleAudioSystemEvent(.routeChanged(routeChange(inputAvailable: true)))
      #expect(engine.recordingPause == nil)
      #expect(engine.isRecording)
      #expect(tapInstaller.installCount() == installsAfterStart + 1)
      #expect(engine.state.withLock { $0.recordingURL } == url)

      _ = try await engine.stopRecording()
    }

    @Test
    func `a paused recording ignores a route that still has no input`() async throws {
      let (engine, _, tapInstaller) = AIOEngine.fakeRecording()
      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }

      await engine.handleAudioSystemEvent(.routeChanged(routeChange(inputAvailable: false)))
      let installsWhilePaused = tapInstaller.installCount()
      await engine.handleAudioSystemEvent(.routeChanged(routeChange(inputAvailable: false)))

      #expect(engine.recordingPause != nil)
      #expect(tapInstaller.installCount() == installsWhilePaused)

      _ = try await engine.stopRecording()
    }

    private func routeChange(inputAvailable: Bool) -> AudioRouteChange {
      AudioRouteChange(
        reason: inputAvailable ? .deviceConnected : .deviceDisconnected,
        previousRoute: nil,
        currentRoute: AudioRouteSnapshot(
          inputs: inputAvailable
            ? [AudioPortSnapshot(name: "Mic", uid: "mic", type: "MicrophoneBuiltIn", channelCount: 1)]
            : [],
          outputs: [],
        ),
        session: AudioSessionSnapshot(
          category: "AVAudioSessionCategoryPlayAndRecord",
          mode: "AVAudioSessionModeDefault",
          options: [],
          sampleRate: 48_000,
          ioBufferDuration: 0.02,
          inputNumberOfChannels: inputAvailable ? 1 : 0,
          isInputAvailable: inputAvailable,
        ),
      )
    }

    private func makeConfiguration() -> RecordingConfiguration {
      RecordingConfiguration(
        inputConfiguration: InputConfiguration(sampleRate: .dvd, channels: .mono),
        outputConfiguration: OutputConfiguration(
          fileFormat: .caf,
          bitDepth: .pcmFloat32,
          quality: .high,
        ),
        outputDestination: .temporary,
      )
    }
  }
#endif
