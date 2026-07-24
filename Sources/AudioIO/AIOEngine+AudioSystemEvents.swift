// © GoodHatsLLC

#if canImport(AVFoundation)
  public import AIOAudioSession
  public import AIOEngineCore

  extension AIOEngine {
    /// Applies one captured audio-system event to recording and playback.
    ///
    /// Recovery failures are published through ``events``. The input is a
    /// platform-neutral value, so callers can forward events from
    /// ``AudioEnvironmentManager/addAudioSystemEventSubscriber(_:)`` or replay
    /// captured events in tests without consulting a live platform session.
    @MainActor
    public func handleAudioSystemEvent(_ event: AudioSystemEvent) async {
      await InterruptionPolicy(owner: self).handle(event)
    }
  }
#endif
