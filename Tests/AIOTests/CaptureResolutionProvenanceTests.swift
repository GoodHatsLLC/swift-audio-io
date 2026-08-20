// © GoodHatsLLC

#if canImport(AVFoundation)
  @testable import AIOAudioSession
  @testable import AIOEngineCore
  import AIOTestSupport
  @testable import AudioIO
  import AVFoundation
  import Foundation
  import Testing

  /// `ResolvedCaptureFormat` is the recording's provenance: what the route was
  /// actually running vs what the file is written at. It must be present from
  /// the start event, track route changes, and clear on stop.
  @Suite(.serialized)
  @MainActor
  struct CaptureResolutionProvenanceTests {
    @Test
    func `start event and observable expose an active resample`() async throws {
      // The HFP shape: a 16 kHz Bluetooth-style route feeding a 48 kHz file.
      let routeFormat = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
      )
      let (engine, _, _) = AIOEngine.fakeRecording(
        tapInstaller: FakeTapInstaller(tapFormat: routeFormat),
      )

      let subscription = engine.events.subscribe()
      let captureTask = Task { () -> ResolvedCaptureFormat? in
        for await event in subscription.events {
          if case .recordingStarted(_, _, let capture) = event {
            return capture
          }
        }
        return nil
      }

      let url = try await engine.startRecording(
        configuration: makeConfiguration(sampleRate: .exact(.dvd)),
      )
      defer { try? FileManager.default.removeItem(at: url) }

      let capture = try #require(await captureTask.value)
      #expect(capture.hardware.sampleRate == SampleRate(16_000))
      #expect(capture.processing.sampleRate == .dvd)
      #expect(capture.isResampling)
      #expect(capture.effectiveSampleRate == SampleRate(16_000))

      #expect(engine.activeCaptureFormat == capture)

      _ = try await engine.stopRecording()
      #expect(engine.activeCaptureFormat == nil)
      #expect(engine.state.withLock { $0.captureResolution } == nil)
    }

    @Test
    func `hardware request records natively with no resample in the provenance`() async throws {
      let routeFormat = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
      )
      let (engine, _, _) = AIOEngine.fakeRecording(
        tapInstaller: FakeTapInstaller(tapFormat: routeFormat),
      )

      let url = try await engine.startRecording(
        configuration: makeConfiguration(sampleRate: .hardware),
      )
      defer { try? FileManager.default.removeItem(at: url) }

      let capture = try #require(engine.activeCaptureFormat)
      #expect(!capture.isResampling)
      #expect(capture.hardware.sampleRate == SampleRate(48_000))
      #expect(capture.processing.sampleRate == SampleRate(48_000))

      _ = try await engine.stopRecording()
    }

    @Test
    func `route change refreshes the provenance while the file rate stays pinned`() async throws {
      // Install 0: 48 kHz route. The route-change reinstall (install 1)
      // reports a 16 kHz route; the file stays at the resolved 48 kHz and the
      // provenance shows the new hardware feeding it through a converter.
      let first = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
      let second = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
      let (engine, _, _) = AIOEngine.fakeRecording(
        tapInstaller: FakeTapInstaller(
          tapFormatForInstall: { $0 == 0 ? first : second },
        ),
      )

      let url = try await engine.startRecording(
        configuration: makeConfiguration(sampleRate: .hardware),
      )
      defer { try? FileManager.default.removeItem(at: url) }
      #expect(engine.activeCaptureFormat?.isResampling == false)

      await engine.handleAudioSystemEvent(
        .routeChanged(
          AudioRouteChange(
            reason: .configurationChanged,
            previousRoute: nil,
            currentRoute: AudioRouteSnapshot(
              inputs: [
                AudioPortSnapshot(
                  name: "Headset", uid: "bt-headset", type: "BluetoothHFP", channelCount: 1,
                )
              ],
              outputs: [],
            ),
            session: AudioSessionSnapshot(
              category: "AVAudioSessionCategoryPlayAndRecord",
              mode: "AVAudioSessionModeDefault",
              options: [],
              sampleRate: 16_000,
              ioBufferDuration: 0.01,
              inputNumberOfChannels: 1,
              isInputAvailable: true,
            ),
          ),
        ),
      )

      let capture = try #require(engine.activeCaptureFormat)
      #expect(capture.hardware.sampleRate == SampleRate(16_000))
      #expect(capture.processing.sampleRate == SampleRate(48_000))
      #expect(capture.isResampling)
      #expect(capture.effectiveSampleRate == SampleRate(16_000))

      _ = try await engine.stopRecording()
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
