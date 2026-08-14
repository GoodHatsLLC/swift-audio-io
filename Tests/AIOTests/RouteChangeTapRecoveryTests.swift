// © GoodHatsLLC

#if canImport(AVFoundation)
  @testable import AIOAudioSession
  @testable import AIOEngineCore
  import AIOTestSupport
  @testable import AudioIO
  import AVFoundation
  import Foundation
  import Testing

  /// Route-change recovery decides between two outcomes: keep the live tap, or
  /// stop the engine and rebuild it. The decision has to rest on what the route
  /// reports, not on the bare existence of a notification — because on iOS the
  /// package's own `AVAudioSession` preference writes post route notifications
  /// back at it, usually with `.categoryChange`.
  ///
  /// These run on macOS: the events are platform-neutral values, so the policy
  /// is exercised without an `AVAudioSession` or a real audio graph.
  @Suite(.serialized)
  struct RouteChangeTapRecoveryTests {
    @Test
    func `a self-induced category event with unchanged facts keeps the live tap`() async throws {
      let (engine, _, tapInstaller) = AIOEngine.fakeRecording(
        tapInstaller: FakeTapInstaller(tapFormat: try captureFormat()),
      )
      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }

      // The first notification has no baseline to compare against, so it
      // reconfigures — "unknown" is not "unchanged".
      await engine.handleAudioSystemEvent(.routeChanged(routeChange(reason: .configurationChanged)))
      let installsAfterBaseline = tapInstaller.installCount()

      // These are the echoes of this package's own preference writes. Same
      // endpoints, same availability, same rate, same channels, same mode —
      // only `reason` differs, and `reason` is not a fact about the microphone.
      for _ in 0..<5 {
        await engine.handleAudioSystemEvent(.routeChanged(routeChange(reason: .categoryChanged)))
      }

      #expect(await engine.isRecording == true)
      #expect(
        tapInstaller.installCount() == installsAfterBaseline,
        """
        Self-induced route events reinstalled the tap \
        \(tapInstaller.installCount() - installsAfterBaseline) times.
        """,
      )

      _ = try await engine.stopRecording()
    }

    @Test
    func `a real format change still reinstalls the tap and recording continues`() async throws {
      let routeFormat = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2),
      )
      let (engine, _, tapInstaller) = AIOEngine.fakeRecording(
        tapInstaller: FakeTapInstaller(
          tapFormatForInstall: { $0 == 0 ? nil : routeFormat },
        ),
      )
      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }

      await engine.handleAudioSystemEvent(.routeChanged(routeChange(reason: .configurationChanged)))
      let installsAfterBaseline = tapInstaller.installCount()

      // A genuine transition: a different endpoint at a different rate and
      // channel count. Nothing about it is inferable from `reason`, which is
      // why the comparison is on the facts.
      await engine.handleAudioSystemEvent(
        .routeChanged(
          routeChange(
            reason: .deviceConnected,
            inputs: [
              AudioPortSnapshot(
                name: "USB Interface", uid: "usb-1", type: "USBAudio", channelCount: 2,
              )
            ],
            sampleRate: 16_000,
            inputChannelCount: 2,
          ),
        ),
      )

      #expect(await engine.isRecording == true)
      #expect(tapInstaller.installCount() == installsAfterBaseline + 1)

      _ = try await engine.stopRecording()
    }

    /// Matching facts are not sufficient on their own. A route that has been
    /// still still needs a rebuild when the graph is not carrying a tap at
    /// those facts.
    @Test
    func `unchanged facts still reinstall when no live tap matches them`() async throws {
      let (engine, _, tapInstaller) = AIOEngine.fakeRecording(
        tapInstaller: FakeTapInstaller(tapFormat: try captureFormat()),
      )
      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }

      await engine.handleAudioSystemEvent(.routeChanged(routeChange(reason: .configurationChanged)))
      let installsAfterBaseline = tapInstaller.installCount()

      // Drop the staged tap the way a graph teardown would, leaving the route
      // facts untouched.
      await MainActor.run { _ = engine.state.consume(\.installedTapBus) }

      await engine.handleAudioSystemEvent(.routeChanged(routeChange(reason: .categoryChanged)))

      #expect(tapInstaller.installCount() == installsAfterBaseline + 1)

      _ = try await engine.stopRecording()
    }

    /// A notification with no session snapshot reports no facts, and unknown
    /// facts can never prove that nothing moved.
    @Test
    func `a route event without session facts always reinstalls`() async throws {
      let (engine, _, tapInstaller) = AIOEngine.fakeRecording(
        tapInstaller: FakeTapInstaller(tapFormat: try captureFormat()),
      )
      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }

      let installsAfterStart = tapInstaller.installCount()
      // An input endpoint is present — so the "no input available" stop path is
      // not what is being measured — but with no session snapshot the rate,
      // channel count, and mode are all unknown.
      let factless = AudioRouteChange(
        reason: .categoryChanged,
        previousRoute: nil,
        currentRoute: AudioRouteSnapshot(
          inputs: [
            AudioPortSnapshot(
              name: "Built-in Microphone", uid: "builtin-mic", type: "MicrophoneBuiltIn",
              channelCount: 1,
            )
          ],
          outputs: [],
        ),
        session: nil,
      )
      await engine.handleAudioSystemEvent(.routeChanged(factless))
      await engine.handleAudioSystemEvent(.routeChanged(factless))

      #expect(tapInstaller.installCount() == installsAfterStart + 2)

      _ = try await engine.stopRecording()
    }

    // MARK: - Helpers

    private func captureFormat() throws -> AVAudioFormat {
      try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
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

    private func routeChange(
      reason: AudioRouteChangeReason,
      inputs: [AudioPortSnapshot] = [
        AudioPortSnapshot(
          name: "Built-in Microphone", uid: "builtin-mic", type: "MicrophoneBuiltIn",
          channelCount: 1,
        )
      ],
      sampleRate: Double = 48_000,
      inputChannelCount: Int = 1,
      mode: String = "AVAudioSessionModeDefault",
    ) -> AudioRouteChange {
      AudioRouteChange(
        reason: reason,
        previousRoute: nil,
        currentRoute: AudioRouteSnapshot(inputs: inputs, outputs: []),
        session: AudioSessionSnapshot(
          category: "AVAudioSessionCategoryPlayAndRecord",
          mode: mode,
          options: [],
          sampleRate: sampleRate,
          ioBufferDuration: 0.01,
          inputNumberOfChannels: inputChannelCount,
          isInputAvailable: true,
        ),
      )
    }
  }
#endif
