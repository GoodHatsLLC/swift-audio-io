// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOAudioSession

  /// Main-actor state owned by audio-system recovery policy.
  @MainActor
  package final class AudioRecoveryState {
    package var pendingRecording: RecordingConfiguration?
    package var pendingPlayback: PlaybackResume?
    package var mediaServicesAreAvailable = true

    package nonisolated init() {}

    package func clear() {
      pendingRecording = nil
      pendingPlayback = nil
    }
  }
#endif
