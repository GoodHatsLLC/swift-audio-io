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
    func `hardware request into AAC keeps the route rate and yields the container`()
      async throws
    {
      // A 96 kHz interface feeding an m4a file: AAC tops out at 48 kHz. The
      // rate outranks the container, so the file becomes linear PCM in CAF at
      // 96 kHz and the substitution is reported in the provenance.
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
      #expect(staged?.exactFormat?.sampleRate == SampleRate(96_000))
      #expect(staged?.outputConfiguration.fileFormat == .caf)
      #expect(url.pathExtension == "caf")
      let capture = await MainActor.run { engine.activeCaptureFormat }
      #expect(
        capture?.substitutions
          == [.containerReplaced(from: .aac, to: .caf, sampleRate: SampleRate(96_000))],
      )

      _ = try await engine.stopRecording()
    }

    @Test
    func `hardware request into a caller-named AAC file clamps the rate and says so`()
      async throws
    {
      // The caller committed to `.m4a` by naming the file, so the container
      // cannot yield; the rate clamps to the nearest AAC-encodable one, and
      // the substitution is reported rather than silent.
      let routeFormat = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 1),
      )
      let (engine, _, _) = AIOEngine.fakeRecording(
        tapInstaller: FakeTapInstaller(tapFormat: routeFormat),
      )
      let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("hardware-clamp-\(UUID().uuidString).m4a")
      let request = RecordingConfiguration(
        input: .microphone(
          MicrophoneRecordingInput(
            format: CaptureFormat(sampleRate: .hardware, channels: .mono),
          ),
        ),
        outputConfiguration: OutputConfiguration(fileFormat: .aac, bitDepth: nil, quality: .high),
        outputDestination: .fileURL(fileURL),
      )

      let url = try await engine.startRecording(configuration: request)
      defer { try? FileManager.default.removeItem(at: url) }

      let staged = engine.state.withLock { $0.recordingConfiguration }
      #expect(staged?.exactFormat?.sampleRate == SampleRate(48_000))
      #expect(staged?.outputConfiguration.fileFormat == .aac)
      let capture = await MainActor.run { engine.activeCaptureFormat }
      #expect(
        capture?.substitutions
          == [
            .sampleRateClamped(
              from: SampleRate(96_000),
              to: SampleRate(48_000),
              fileFormat: .aac,
            )
          ],
      )

      _ = try await engine.stopRecording()
    }

    @Test
    func `interruption resume keeps the file rate and converts from the new route`() async throws
    {
      // Install 0 happens on a 48 kHz route; the post-interruption resume
      // (install 1) happens after AirPods connected — a 24 kHz route. The
      // contract was fixed at start, so the same file stays at 48 kHz and the
      // 24 kHz route is converted into it; the provenance says so.
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
      #expect(await engine.isRecording == true)
      await engine.handleAudioSystemEvent(.interruptionEnded(shouldResume: true))

      #expect(await MainActor.run { engine.recordingPause } == nil)
      #expect(engine.state.withLock { $0.recordingURL } == url)
      let resumed = engine.state.withLock { $0.recordingConfiguration }
      #expect(resumed?.exactFormat?.sampleRate == SampleRate(48_000))
      let capture = await MainActor.run { engine.activeCaptureFormat }
      #expect(capture?.hardware.sampleRate == SampleRate(24_000))
      #expect(capture?.processing.sampleRate == SampleRate(48_000))
      #expect(capture?.isResampling == true)
      #expect(
        engine.state.withLock { $0.requestedRecordingConfiguration } == request,
      )

      _ = try await engine.stopRecording()
    }

    @Test
    func `hardware resolution prepares a graph that has an I/O node`() {
      // Regression. `readHardwareInputSampleRate` called `engine.prepare()`
      // before anything had read an I/O node. `AVAudioEngine` creates
      // `inputNode`/`outputNode` lazily, so the graph held only the attached
      // `player`, and `AVAudioEngineGraph::Initialize` asserted
      // `inputNode != nullptr || outputNode != nullptr`. That assertion raises
      // an Objective-C exception, which no Swift `catch` intercepts, so the
      // first `.hardware` recording after launch aborted the process.
      //
      // Every other case in this suite injects a tap installer, which makes
      // `PreparationInputs.seamResolvedConfiguration` non-nil and returns from
      // `resolveConfiguration` before the graph is touched at all — which is
      // why a thoroughly covered feature still shipped this crash. Only a
      // `.live` environment reaches the real read, and a regression shows up
      // here as a crashed test process rather than a failed expectation.
      let engine = AIOEngine(recordingEnvironment: .live)

      let sampleRate = engine.readHardwareInputSampleRate()

      // A route that reports nothing is a legitimate transient answer that the
      // start deadline loop retries; a route that reports at all must report a
      // usable rate.
      if let sampleRate {
        #expect(sampleRate > 0)
      }
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
