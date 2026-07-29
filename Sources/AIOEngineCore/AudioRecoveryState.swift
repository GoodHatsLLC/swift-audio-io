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

    package nonisolated init() {}

    package func clear() {
      pendingRecording = nil
      pendingPlayback = nil
      playbackResumptionSuppressed = false
    }
  }
#endif
