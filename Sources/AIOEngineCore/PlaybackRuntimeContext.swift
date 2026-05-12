// © GoodHatsLLC

#if canImport(AVFoundation)
  import Tools

  extension AIOEngine {
    package struct PlaybackRuntimeContext {
      package var pendingPlaybackResume: PlaybackResume?
      package var defaultPlaybackPollingInterval: Duration = .seconds(0.5)
      package var lastPlaybackStateSignature: PlaybackStateSignature?
      package var playbackTask: MainActorOwnedWork?
      package var scrubTask: MainActorOwnedWork?

      package init() {}
    }
  }
#endif
