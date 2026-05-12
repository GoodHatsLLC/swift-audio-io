// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOEngineCore
  package import AVFoundation
  import Foundation

  extension AIOEngine {
    private var playbackRuntime: PlaybackRuntime {
      PlaybackRuntime(owner: self)
    }

    @MainActor
    public func play(url: URL) async throws(AIOError) -> Playback {
      try await playbackRuntime.play(url: url)
    }

    @MainActor
    public func play(url: URL, playbackPollingInterval: Duration?) async throws(AIOError)
      -> Playback
    {
      try await playbackRuntime.play(
        url: url,
        playbackPollingInterval: playbackPollingInterval,
      )
    }

    @MainActor
    public func playSegment(
      url: URL,
      startTime: TimeInterval,
      endTime: TimeInterval,
      onComplete: (@MainActor @Sendable () -> Void)? = nil,
      playbackPollingInterval: Duration? = nil,
    ) async throws(AIOError) -> Playback {
      try await playbackRuntime.playSegment(
        url: url,
        startTime: startTime,
        endTime: endTime,
        onComplete: onComplete,
        playbackPollingInterval: playbackPollingInterval,
      )
    }

    @MainActor
    package func resetPlaybackTimer(to instance: PlaybackInstance) {
      playbackRuntime.resetPlaybackTimer(to: instance)
    }

    @concurrent
    package nonisolated func scrub(
      framePosition: AVAudioFramePosition,
      file: AVAudioFile,
      newInstance: PlaybackInstance,
      play: Bool,
    ) async {
      await playbackRuntime.scrub(
        framePosition: framePosition,
        file: file,
        newInstance: newInstance,
        play: play,
        callbackTasks: playbackCallbackTasks,
      )
    }

    /// Scrubs the active playback.
    ///
    /// `time` is segment-relative for `playSegment` playback and file-relative for whole-file
    /// playback.
    @MainActor
    public func scrub(
      to time: TimeInterval,
      updatePlaybackTimer: Bool = true,
    ) throws(AIOError) -> Playback? {
      try playbackRuntime.scrub(
        to: time,
        updatePlaybackTimer: updatePlaybackTimer,
      )
    }

    @MainActor
    public func stopPlayback() async {
      await playbackRuntime.stopPlayback()
    }

    @MainActor
    public func pausePlayback() {
      playbackRuntime.pausePlayback()
    }

    @MainActor
    public func resumePlayback() {
      playbackRuntime.resumePlayback()
    }

    @MainActor
    public func setPlaybackMixerAmplitude(_ amplitude: Float) {
      playbackRuntime.setPlaybackMixerAmplitude(amplitude)
    }

    package nonisolated func cleanupPlaybackInstance(_ instance: PlaybackInstance) {
      playbackRuntime.cleanupPlaybackInstance(instance)
    }

    package nonisolated func stopPlayerIfNeeded() async {
      await playbackRuntime.stopPlayerIfNeeded()
    }

    @MainActor
    package func capturePlaybackResumeState() -> PlaybackResume? {
      playbackRuntime.capturePlaybackResumeState()
    }

    @MainActor
    package func restartPlayback(from resume: PlaybackResume) async {
      await playbackRuntime.restartPlayback(from: resume)
    }
  }
#endif
