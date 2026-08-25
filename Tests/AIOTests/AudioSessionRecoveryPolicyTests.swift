// © GoodHatsLLC

import AIOTestSupport
import Foundation
import Testing
import Tools

@testable import AIOAudioSession
@testable import AIOEngineCore
@testable import AudioIO

/// The iOS 27 session-state and resumption channels feeding the shared
/// recovery policy.
///
/// These run on every platform: the events are platform-neutral values, so the
/// policy is exercised without an `AVAudioSession`.
struct AudioSessionRecoveryPolicyTests {
  @Test
  @MainActor
  func `a system deactivation stages recovery when no interruption is staged`() async {
    let engine = AIOEngine()
    engine.audioRecoveryState.pendingPlayback = resume(wasPlaying: true)
    let staged = engine.audioRecoveryState.pendingPlayback

    // Nothing staged by an interruption yet, so the session-state channel is
    // free to act. With no live playback the policy has nothing to stop, but
    // it must not discard what is already staged either.
    await engine.handleAudioSystemEvent(
      .sessionDeactivated(AudioSessionDeactivation(source: .system)),
    )

    #expect(engine.audioRecoveryState.pendingPlayback == staged)
  }

  @Test
  @MainActor
  func `a system deactivation does not re-pause a recording an interruption already paused`()
    async throws
  {
    let (engine, _, tapInstaller) = AIOEngine.fakeRecording()
    let url = try await engine.startRecording(configuration: configuration())
    defer { try? FileManager.default.removeItem(at: url) }

    await engine.handleAudioSystemEvent(.interruptionBegan)
    let pause = try #require(engine.recordingPause)
    let installsWhilePaused = tapInstaller.installCount()

    await engine.handleAudioSystemEvent(
      .sessionDeactivated(
        AudioSessionDeactivation(source: .system, interruptionReason: .default),
      ),
    )

    // Deduplication: one interruption surfaces on both the interruption and
    // the session-state channel on iOS 27. The interruption owns the pause.
    #expect(engine.recordingPause == pause)
    #expect(engine.isRecording)
    #expect(tapInstaller.installCount() == installsWhilePaused)
    #expect(engine.audioRecoveryState.pendingPlayback == nil)
    _ = try await engine.stopRecording()
  }

  @Test
  @MainActor
  func `an app-requested deactivation never stages recovery`() async {
    let engine = AIOEngine()

    await engine.handleAudioSystemEvent(
      .sessionDeactivated(AudioSessionDeactivation(source: .app)),
    )

    #expect(engine.recordingPause == nil)
    #expect(engine.audioRecoveryState.pendingPlayback == nil)
  }

  @Test
  @MainActor
  func `session activation is diagnostics only and stages nothing`() async {
    let engine = AIOEngine()

    await engine.handleAudioSystemEvent(.sessionActivated)

    #expect(engine.recordingPause == nil)
    #expect(engine.audioRecoveryState.pendingPlayback == nil)
    #expect(engine.audioRecoveryState.playbackResumptionSuppressed == false)
  }

  @Test
  @MainActor
  func `a positive resumption recommendation never resumes a paused recording`() async throws {
    let (engine, _, tapInstaller) = AIOEngine.fakeRecording()
    let url = try await engine.startRecording(configuration: configuration())
    defer { try? FileManager.default.removeItem(at: url) }
    await engine.handleAudioSystemEvent(.interruptionBegan)
    let installsWhilePaused = tapInstaller.installCount()

    await engine.handleAudioSystemEvent(.resumptionRecommended(true))

    // The recommendation is advice about *playback*. A recording resumes on
    // the interruption ending (or the session coming back), not on a hint.
    #expect(engine.recordingPause != nil)
    #expect(tapInstaller.installCount() == installsWhilePaused)
    _ = try await engine.stopRecording()
  }

  @Test
  @MainActor
  func `a positive resumption recommendation consumes pending playback`() async {
    let engine = AIOEngine()
    engine.audioRecoveryState.pendingPlayback = resume(wasPlaying: true)

    await engine.handleAudioSystemEvent(.resumptionRecommended(true))

    // Playback restart is attempted, so the staged value is consumed. The
    // restart itself fails on a missing file and is reported through `events`
    // — covered by `AudioSystemEventTests`.
    #expect(engine.audioRecoveryState.pendingPlayback == nil)
    #expect(engine.audioRecoveryState.playbackResumptionSuppressed == false)
  }

  @Test
  @MainActor
  func `a negative resumption recommendation suppresses the automatic playback restart`() async {
    let engine = AIOEngine()
    engine.audioRecoveryState.pendingPlayback = resume(wasPlaying: true)

    await engine.handleAudioSystemEvent(.resumptionRecommended(false))
    #expect(engine.audioRecoveryState.playbackResumptionSuppressed)

    await engine.handleAudioSystemEvent(.interruptionEnded(shouldResume: true))

    // The interruption said resume; the system said do not. The system wins
    // for playback, and the staged state is cleared either way.
    #expect(engine.audioRecoveryState.pendingPlayback == nil)
    #expect(engine.audioRecoveryState.playbackResumptionSuppressed == false)
    #expect(engine.isPlayback == false)
  }

  @Test
  @MainActor
  func `suppression does not block recording resumption`() async throws {
    let (engine, _, tapInstaller) = AIOEngine.fakeRecording()
    let url = try await engine.startRecording(configuration: configuration())
    defer { try? FileManager.default.removeItem(at: url) }
    await engine.handleAudioSystemEvent(.interruptionBegan)
    engine.audioRecoveryState.pendingPlayback = resume(wasPlaying: true)
    let installsWhilePaused = tapInstaller.installCount()

    await engine.handleAudioSystemEvent(.resumptionRecommended(false))
    await engine.handleAudioSystemEvent(.interruptionEnded(shouldResume: true))

    // Suppression is a playback rule only; the recording resumes into its
    // file regardless.
    #expect(engine.recordingPause == nil)
    #expect(engine.isRecording)
    #expect(tapInstaller.installCount() == installsWhilePaused + 1)
    _ = try await engine.stopRecording()
  }

  @Test
  func `new session events are hashable values`() {
    let deactivation = AudioSessionDeactivation(
      source: .system,
      interruptionReason: .builtInMicMuted,
    )
    let events: Set<AudioSystemEvent> = [
      .sessionActivated,
      .sessionDeactivated(deactivation),
      .resumptionRecommended(true),
      .resumptionRecommended(false),
    ]

    #expect(events.count == 4)
    #expect(events.contains(.sessionDeactivated(deactivation)))
    #expect(!events.contains(.sessionDeactivated(AudioSessionDeactivation(source: .app))))
  }

  // MARK: - Helpers

  private func resume(wasPlaying: Bool) -> PlaybackResume {
    PlaybackResume(
      fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-\(UUID().uuidString).caf"),
      time: 0,
      duration: 1,
      wasPlaying: wasPlaying,
      pollingInterval: Duration.seconds(1),
      sampleRate: 48_000,
    )
  }

  private func configuration() -> RecordingConfiguration {
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
