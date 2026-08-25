// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOAudioSession
  import Tools

  /// Main-actor state owned by audio-system recovery policy.
  @MainActor
  package final class AudioRecoveryState {
    package var pendingPlayback: PlaybackResume?
    /// The cadence retrying a paused recording's resume; see
    /// `AIOEngine.pauseRecording(reason:)`.
    package var resumeRetryTask: MainActorOwnedWork?
    package var mediaServicesAreAvailable = true

    /// Set when the system recommends *against* resuming (iOS 27's
    /// `resumptionRecommendation` channel). It suppresses the automatic
    /// playback restart that `interruptionEnded(shouldResume: true)` would
    /// otherwise perform. It never affects recording, which is only ever
    /// restarted through the pending-recording flow.
    package var playbackResumptionSuppressed = false

    /// The route facts the last route notification reported.
    ///
    /// Route recovery compares against this to tell a self-induced event — the
    /// `.categoryChange` an `AVAudioSession` preference write posts back at the
    /// process that made it — from a transition that actually changed what the
    /// microphone delivers.
    ///
    /// `nil` means "no baseline", which is deliberately *not* treated as
    /// "unchanged": the first route notification of a recording cannot prove
    /// anything, so it reconfigures. Only the second and later identical ones
    /// are recognised as no-ops, and that is enough to break a feedback loop,
    /// which is by definition repetition.
    package var observedInputFacts: AudioInputFacts?

    package nonisolated init() {}

    package func clear() {
      pendingPlayback = nil
      playbackResumptionSuppressed = false
    }
  }
#endif
