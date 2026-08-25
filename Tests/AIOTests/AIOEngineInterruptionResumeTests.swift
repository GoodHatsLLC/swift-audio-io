// © GoodHatsLLC

#if canImport(AVFoundation)
  @testable import AIOEngineCore
  import AIOTestSupport
  import AVFoundation
  import Foundation
  import Testing

  @testable import AIOAudioSession
  import AudioIO

  /// Exercises the audio-session interruption **pause and resume** for
  /// recording.
  ///
  /// The start runs the real `RecordingLifecycle.attemptRecordingStart`; only
  /// the tap install, engine start, and graph teardown are faked. A pause is
  /// observable as `recordingPause` with `isRecording` still true, and a
  /// resume as one more tap install into the same, never-closed file.
  @MainActor
  struct AIOEngineInterruptionResumeTests {
    @Test
    func `interruption pauses recording and the ending resumes it into the same file`()
      async throws
    {
      let (engine, backend, tapInstaller) = AIOEngine.fakeRecording()

      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }
      #expect(backend.startCalls == 1)
      let installsAfterStart = tapInstaller.installCount()

      await engine.handleAudioSystemEvent(.interruptionBegan)
      #expect(engine.isRecording)
      #expect(engine.recordingPause?.reason == .interruption)
      #expect(engine.state.withLock { $0.recordingURL } == url)

      await engine.handleAudioSystemEvent(.interruptionEnded(shouldResume: true))
      #expect(engine.recordingPause == nil)
      #expect(engine.isRecording)
      #expect(tapInstaller.installCount() == installsAfterStart + 1)
      #expect(engine.state.withLock { $0.recordingURL } == url)
      // The file never closed, so the capture backend never restarted.
      #expect(backend.startCalls == 1)

      _ = try await engine.stopRecording()
    }

    @Test
    func `interruption ending without resume advice still resumes a recording`() async throws {
      let (engine, _, tapInstaller) = AIOEngine.fakeRecording()

      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }
      let installsAfterStart = tapInstaller.installCount()

      await engine.handleAudioSystemEvent(.interruptionBegan)
      #expect(engine.recordingPause != nil)

      // The user armed the recording; the system's advice is about playback.
      await engine.handleAudioSystemEvent(.interruptionEnded(shouldResume: false))
      #expect(engine.recordingPause == nil)
      #expect(engine.isRecording)
      #expect(tapInstaller.installCount() == installsAfterStart + 1)

      _ = try await engine.stopRecording()
    }

    @Test
    func `stopping a paused recording completes it`() async throws {
      let (engine, _, _) = AIOEngine.fakeRecording()

      let url = try await engine.startRecording(configuration: makeConfiguration())
      defer { try? FileManager.default.removeItem(at: url) }
      await engine.handleAudioSystemEvent(.interruptionBegan)
      #expect(engine.recordingPause != nil)

      let completion = try await engine.stopRecording()
      #expect(completion.completedURL == url)
      #expect(engine.isRecording == false)
      #expect(engine.recordingPause == nil)
    }

    private func makeConfiguration() -> RecordingConfiguration {
      let input = InputConfiguration(
        sampleRate: .dvd,
        channels: .mono,
      )
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
  }
#endif
