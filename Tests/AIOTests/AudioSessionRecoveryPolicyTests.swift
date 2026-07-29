// © GoodHatsLLC

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
  func `a system deactivation does not re-stage over an interruption's pending recording`()
    async
  {
    let engine = AIOEngine()
    let pending = configuration()
    engine.audioRecoveryState.pendingRecording = pending

    await engine.handleAudioSystemEvent(
      .sessionDeactivated(
        AudioSessionDeactivation(source: .system, interruptionReason: .default),
      ),
    )

    // Deduplication: one interruption surfaces on both the interruption and
    // the session-state channel on iOS 27. The interruption owns recovery.
    #expect(engine.audioRecoveryState.pendingRecording == pending)
    #expect(engine.audioRecoveryState.pendingPlayback == nil)
  }

  @Test
  @MainActor
  func `an app-requested deactivation never stages recovery`() async {
    let engine = AIOEngine()

    await engine.handleAudioSystemEvent(
      .sessionDeactivated(AudioSessionDeactivation(source: .app)),
    )

    #expect(engine.audioRecoveryState.pendingRecording == nil)
    #expect(engine.audioRecoveryState.pendingPlayback == nil)
  }

  @Test
  @MainActor
  func `session activation is diagnostics only and stages nothing`() async {
    let engine = AIOEngine()

    await engine.handleAudioSystemEvent(.sessionActivated)

    #expect(engine.audioRecoveryState.pendingRecording == nil)
    #expect(engine.audioRecoveryState.pendingPlayback == nil)
    #expect(engine.audioRecoveryState.playbackResumptionSuppressed == false)
  }

  @Test
  @MainActor
  func `a positive resumption recommendation never restarts a pending recording`() async {
    let engine = AIOEngine()
    let pending = configuration()
    engine.audioRecoveryState.pendingRecording = pending

    await engine.handleAudioSystemEvent(.resumptionRecommended(true))

    // The product rule: leaving a live recording stops it. A system hint is
    // never sufficient cause to put the microphone back on. The staged
    // recording survives for the pending-recording flow to decide on.
    #expect(engine.audioRecoveryState.pendingRecording == pending)
    #expect(engine.isRecording == false)
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
  func `suppression does not block recording recovery`() async {
    let engine = AIOEngine()
    let pending = configuration()
    engine.audioRecoveryState.pendingRecording = pending
    engine.audioRecoveryState.pendingPlayback = resume(wasPlaying: true)

    await engine.handleAudioSystemEvent(.resumptionRecommended(false))
    await engine.handleAudioSystemEvent(.interruptionEnded(shouldResume: true))

    // Suppression is a playback rule only; the recording path is untouched by
    // it and clears its staged state through the normal restart flow.
    #expect(engine.audioRecoveryState.pendingRecording == nil)
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
