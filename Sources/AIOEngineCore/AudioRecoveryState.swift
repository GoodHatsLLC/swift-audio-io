// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOAudioSession

  /// Main-actor state owned by audio-system recovery policy.
  @MainActor
  package final class AudioRecoveryState {
    package var pendingRecording: RecordingConfiguration?
    package var pendingPlayback: PlaybackResume?
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
      pendingRecording = nil
      pendingPlayback = nil
      playbackResumptionSuppressed = false
    }
  }
#endif
