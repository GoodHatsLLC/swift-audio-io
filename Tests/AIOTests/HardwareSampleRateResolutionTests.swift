// © GoodHatsLLC

#if canImport(AVFoundation)
  @testable import AIOAudioSession
  @testable import AIOEngineCore
  import AIOTestSupport
  @testable import AudioIO
  import AVFoundation
  import Foundation
  import Testing

  /// A `.hardware` sample-rate request has no concrete rate until bring-up
  /// observes the route. These exercise the resolution seam end to end on the
  /// real lifecycle: the staged configuration must be exact, the request must
  /// be preserved for identity checks, and restarts must re-resolve.
  @Suite(.serialized)
  struct HardwareSampleRateResolutionTests {
    @Test
    func `hardware request resolves the staged configuration to the route rate`() async throws {
      let routeFormat = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
      )
      let (engine, _, _) = AIOEngine.fakeRecording(
        tapInstaller: FakeTapInstaller(tapFormat: routeFormat),
      )
      let request = makeConfiguration(sampleRate: .hardware)

      let url = try await engine.startRecording(configuration: request)
      defer { try? FileManager.default.removeItem(at: url) }

      let (staged, stagedRequest) = engine.state.withLock {
        ($0.recordingConfiguration, $0.requestedRecordingConfiguration)
      }
      #expect(staged?.requestedFormat.exactSampleRate == SampleRate(48_000))
      #expect(staged?.exactFormat?.sampleRate == SampleRate(48_000))
      #expect(stagedRequest == request)
      #expect(stagedRequest?.requestedFormat.sampleRate == .hardware)

      _ = try await engine.stopRecording()
      let cleared = engine.state.withLock {
        ($0.recordingConfiguration, $0.requestedRecordingConfiguration)
      }
      #expect(cleared.0 == nil)
      #expect(cleared.1 == nil)
    }

    @Test
    func `exact request stages itself as both request and resolved configuration`() async throws {
      let (engine, _, _) = AIOEngine.fakeRecording(
        tapInstaller: FakeTapInstaller(
          tapFormat: try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)),
        ),
      )
      let request = makeConfiguration(sampleRate: .exact(.cd))

      let url = try await engine.startRecording(configuration: request)
      defer { try? FileManager.default.removeItem(at: url) }

      let (staged, stagedRequest) = engine.state.withLock {
        ($0.recordingConfiguration, $0.requestedRecordingConfiguration)
      }
      #expect(staged == request)
      #expect(stagedRequest == request)
      #expect(staged?.exactFormat?.sampleRate == .cd)

      _ = try await engine.stopRecording()
    }

    @Test
    func `hardware request into AAC clamps an unencodable route rate to the nearest supported`()
      async throws
    {
      // A 96 kHz interface feeding an m4a file: AAC tops out at 48 kHz, so the
      // resolved file rate must clamp while the tap keeps the hardware format.
      let routeFormat = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 1),
      )
      let (engine, _, _) = AIOEngine.fakeRecording(
        tapInstaller: FakeTapInstaller(tapFormat: routeFormat),
      )
      let request = RecordingConfiguration(
        input: .microphone(
          MicrophoneRecordingInput(
            format: CaptureFormat(sampleRate: .hardware, channels: .mono),
          ),
        ),
        outputConfiguration: OutputConfiguration(fileFormat: .aac, bitDepth: nil, quality: .high),
      )

      let url = try await engine.startRecording(configuration: request)
      defer { try? FileManager.default.removeItem(at: url) }

      let staged = engine.state.withLock { $0.recordingConfiguration }
      #expect(staged?.exactFormat?.sampleRate == SampleRate(48_000))

      _ = try await engine.stopRecording()
    }

    @Test
    func `interruption restart re-resolves a hardware request against the new route`() async throws
    {
      // Install 0 happens on a 48 kHz route; the post-interruption restart
      // (install 1) happens after AirPods connected — a 24 kHz route. The
      // stash must carry the *request*, so the new file adopts 24 kHz instead
      // of pinning the stale 48 kHz resolution.
      let first = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
      let second = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
      let (engine, _, _) = AIOEngine.fakeRecording(
        tapInstaller: FakeTapInstaller(
          tapFormatForInstall: { $0 == 0 ? first : second },
        ),
      )
      let request = makeConfiguration(sampleRate: .hardware)

      let url = try await engine.startRecording(configuration: request)
      defer { try? FileManager.default.removeItem(at: url) }
      #expect(
        engine.state.withLock { $0.recordingConfiguration }?.exactFormat?.sampleRate
          == SampleRate(48_000),
      )

      await engine.handleAudioSystemEvent(.interruptionBegan)
      #expect(await engine.isRecording == false)
      await engine.handleAudioSystemEvent(.interruptionEnded(shouldResume: true))

      #expect(await engine.isRecording == true)
      let restagedURL = engine.state.withLock { $0.recordingURL }
      defer { if let restagedURL { try? FileManager.default.removeItem(at: restagedURL) } }
      let restaged = engine.state.withLock { $0.recordingConfiguration }
      #expect(restaged?.exactFormat?.sampleRate == SampleRate(24_000))
      #expect(
        engine.state.withLock { $0.requestedRecordingConfiguration } == request,
      )

      _ = try await engine.stopRecording()
    }

    @Test
    func `hardware request fails static validation before touching a route`() {
      // AAC has no PCM sample width; supplying one is a static issue that must
      // surface for a .hardware request without any resolution having run.
      let configuration = RecordingConfiguration(
        input: .microphone(
          MicrophoneRecordingInput(
            format: CaptureFormat(sampleRate: .hardware, channels: .mono),
          ),
        ),
        outputConfiguration: OutputConfiguration(
          fileFormat: .aac, bitDepth: .pcmInt16, quality: .high,
        ),
      )
      let validation = configuration.validate()
      #expect(!validation.isValid)
      #expect(
        validation.issues.contains {
          if case .unsupportedBitDepth = $0 { return true }
          return false
        },
      )
    }

    @Test
    func `resolution clamp helpers pick the nearest encodable rate`() {
      #expect(FileFormat.aac.nearestSupportedSampleRate(to: SampleRate(96_000)) == SampleRate(48_000))
      #expect(FileFormat.aac.nearestSupportedSampleRate(to: SampleRate(22_050)) == SampleRate(22_050))
      #expect(FileFormat.wav.nearestSupportedSampleRate(to: SampleRate(4_000)) == SampleRate(8_000))
      #expect(
        FileFormat.wav.nearestSupportedSampleRate(to: SampleRate(200_000)) == SampleRate(192_000))
    }

    @Test
    func `configuration resolution adopts the hardware rate for PCM formats`() {
      let request = makeConfiguration(sampleRate: .hardware)
      let resolved = request.resolved(hardwareSampleRate: SampleRate(44_100))
      #expect(resolved.exactFormat?.sampleRate == SampleRate(44_100))
      #expect(resolved.requestedFormat.channels == .mono)
      #expect(resolved.outputConfiguration == request.outputConfiguration)

      // Exact requests are already resolved; the hardware rate is irrelevant.
      let exact = makeConfiguration(sampleRate: .exact(.cd))
      #expect(exact.resolved(hardwareSampleRate: SampleRate(48_000)) == exact)
    }

    // MARK: - Helpers

    private func makeConfiguration(sampleRate: RecordingSampleRate) -> RecordingConfiguration {
      RecordingConfiguration(
        input: .microphone(
          MicrophoneRecordingInput(
            format: CaptureFormat(sampleRate: sampleRate, channels: .mono),
          ),
        ),
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
