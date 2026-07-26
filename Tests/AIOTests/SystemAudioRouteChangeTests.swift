// © GoodHatsLLC

#if os(macOS)
  @testable import AIOEngineCore
  import AIOTestSupport
  import AVFoundation
  import Testing

  @testable import AIOAudioSession
  @testable import AudioIO

  /// A route change during a system-audio recording must not touch the
  /// AVAudioEngine input tap: the recording is fed by the Core Audio process
  /// tap, and reinstalling the input tap would start the microphone and
  /// overwrite the shared tap converter — injecting mic audio into (or
  /// silencing) the system-audio recording.
  @MainActor
  struct SystemAudioRouteChangeTests {
    @Test
    func `route change during system-audio recording does not reinstall the input tap`()
      async throws
    {
      // Audio-system recovery resolves this seam before dispatching a reinstall,
      // so an install means the system-audio guard was bypassed.
      let tapInstaller = FakeTapInstaller(failure: .engineError)
      let (engine, _, _) = AIOEngine.fakeRecording(tapInstaller: tapInstaller)
      let configuration = makeSystemAudioConfiguration()

      // Fabricate an established system-audio recording: staged configuration
      // plus the published `isRecording` flag. The real capture session needs
      // system-audio TCC permission, so the state is staged directly.
      engine.state.withLock { $0.recordingConfiguration = configuration }
      engine.isRecording = true

      let change = AudioRouteChange(
        reason: .configurationChanged,
        previousRoute: nil,
        currentRoute: AudioRouteSnapshot(inputs: [], outputs: []),
      )
      await engine.handleAudioSystemEvent(.routeChanged(change))

      #expect(tapInstaller.installCount() == 0)
      #expect(engine.isRecording == true)
    }

    @Test
    func `reinstallTap is a no-op for system-audio configurations`() async throws {
      let engine = AIOEngine()
      let configuration = makeSystemAudioConfiguration()
      let processingFormat = try #require(configuration.processingFormat)

      // Would throw or mutate the graph without the guard; the system-audio
      // guard must return nil before touching the AVAudioEngine.
      let result = try engine.reinstallTap(
        configuration: configuration,
        processingFormat: processingFormat,
        stopEngine: false,
      )

      #expect(result == nil)
    }

    private func makeSystemAudioConfiguration() -> RecordingConfiguration {
      RecordingConfiguration(
        input: .systemAudio(
          SystemAudioRecordingInput(
            format: InputConfiguration(sampleRate: .dvd, channels: .stereo),
          ),
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
