// © GoodHatsLLC

#if canImport(AVFoundation)
  extension AIOEngine {
    package struct PlaybackRuntimeContext {
      package var pendingPlaybackResume: PlaybackResume?
      package var defaultPlaybackPollingInterval: Duration = .seconds(0.5)
      package var lastPlaybackStateSignature: PlaybackStateSignature?
      package var playbackTask: Task<Void, Never>?
      package var scrubTask: Task<Void, Never>?

      package init() {}
    }
  }
#endif
