// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOSupport
  import AIOEngineCore
  import AsyncAlgorithms
  import AVFoundation
  import Foundation
  import os
  import Tools

  private let log = SystemLog.make()

  struct PlaybackRuntime {
    let owner: AIOEngine

    @MainActor
    func play(url: URL) async throws(AIOEngine.AIOError) -> AIOEngine.Playback {
      try await play(url: url, playbackPollingInterval: nil)
    }

    @MainActor
    func play(
      url: URL,
      playbackPollingInterval: Duration?,
    ) async throws(AIOEngine.AIOError) -> AIOEngine.Playback {
      guard !owner.isRecording else {
        throw AIOEngine.AIOError.cannotPlayWhileRecording
      }

      try owner.configureAudioSessionForPlayback()

      let file: AVAudioFile
      do {
        file = try AVAudioFile(forReading: url)
      } catch {
        throw AIOEngine.AIOError.audioFileFailed(
          operation: .openForReading, url: url, error: ErrorContext(error),
        )
      }
      guard file.length > 0 else {
        throw AIOEngine.AIOError.audioFileFailed(
          operation: .openForReading,
          url: url,
          error: ErrorContext(EmptyAudioFileError(url: url)),
        )
      }

      let interval =
        (playbackPollingInterval ?? owner.defaultPlaybackPollingInterval) > .zero
        ? (playbackPollingInterval ?? owner.defaultPlaybackPollingInterval)
        : .seconds(0.5)
      let playbackInstance = PlaybackInstance(
        id: .init(),
        file: file,
        startFrame: file.framePosition,
        pollingInterval: interval,
      )

      if owner.getPlayback() != nil {
        owner.playbackState[locked: \.playbackInstance] = nil
        owner.setPlayback(nil)
      }
      owner.playbackState[locked: \.playbackInstance] = playbackInstance

      let startResult = await owner.withEngineControlQueueResult { [weak owner] in
        guard let owner else { return }
        unsafe owner.player.stop()
        unsafe owner.engine.stop()
        unsafe owner.engine.reset()
        if unsafe !owner.engine.attachedNodes.contains(owner.player) {
          unsafe owner.engine.attach(owner.player)
        }
        unsafe owner.engine.connect(
          owner.player,
          to: owner.engine.mainMixerNode,
          format: file.processingFormat,
        )
        unsafe owner.player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) {
          [weak owner, playbackInstance] _ in
          guard let owner else { return }
          PlaybackRuntime(owner: owner).cleanupPlaybackInstance(playbackInstance)
        }
        try unsafe owner.engine.start()
        unsafe owner.player.play()
      }
      if case .failure(let error) = startResult {
        throw AIOEngine.AIOError.engineStartFailed(error: ErrorContext(error))
      }

      let playback = owner.getPlayback(for: playbackInstance)
      owner.setPlayback(playback)
      resetPlaybackTimer(to: playbackInstance)
      return playback
    }

    @MainActor
    func playSegment(
      url: URL,
      startTime: TimeInterval,
      endTime: TimeInterval,
      onComplete: (@MainActor @Sendable () -> Void)? = nil,
      playbackPollingInterval: Duration? = nil,
    ) async throws(AIOEngine.AIOError) -> AIOEngine.Playback {
      guard !owner.isRecording else {
        throw AIOEngine.AIOError.cannotPlayWhileRecording
      }

      try owner.configureAudioSessionForPlayback()

      let file: AVAudioFile
      do {
        file = try AVAudioFile(forReading: url)
      } catch {
        throw AIOEngine.AIOError.audioFileFailed(
          operation: .openForReading, url: url, error: ErrorContext(error),
        )
      }
      let sampleRate = file.processingFormat.sampleRate
      let startFrame = AVAudioFramePosition(startTime * sampleRate)
      let duration = endTime - startTime
      let frameCount = AVAudioFrameCount(duration * sampleRate)

      guard startFrame >= 0, frameCount > 0,
        AVAudioFramePosition(startFrame) + AVAudioFramePosition(frameCount) <= file.length
      else {
        throw AIOEngine.AIOError.invalidTimeRange
      }

      let interval =
        (playbackPollingInterval ?? owner.defaultPlaybackPollingInterval) > .zero
        ? (playbackPollingInterval ?? owner.defaultPlaybackPollingInterval)
        : .seconds(0.5)
      let playbackInstance = PlaybackInstance(
        id: .init(),
        file: file,
        startFrame: startFrame,
        pollingInterval: interval,
      )

      if owner.getPlayback() != nil {
        owner.playbackState[locked: \.playbackInstance] = nil
        owner.setPlayback(nil)
      }
      owner.playbackState[locked: \.playbackInstance] = playbackInstance

      let startResult = await owner.withEngineControlQueueResult { [weak owner] in
        guard let owner else { return }
        unsafe owner.player.stop()
        unsafe owner.engine.stop()
        unsafe owner.engine.reset()
        if unsafe !owner.engine.attachedNodes.contains(owner.player) {
          unsafe owner.engine.attach(owner.player)
        }
        unsafe owner.engine.connect(
          owner.player,
          to: owner.engine.mainMixerNode,
          format: file.processingFormat,
        )
        unsafe owner.player.scheduleSegment(
          file,
          startingFrame: startFrame,
          frameCount: frameCount,
          at: nil,
          completionCallbackType: .dataPlayedBack,
        ) { [weak owner, playbackInstance] _ in
          guard let owner else { return }
          PlaybackRuntime(owner: owner).cleanupPlaybackInstance(playbackInstance)
          if let onComplete {
            Task { @MainActor in
              onComplete()
            }
          }
        }
        try unsafe owner.engine.start()
        unsafe owner.player.play()
      }
      if case .failure(let error) = startResult {
        throw AIOEngine.AIOError.engineStartFailed(error: ErrorContext(error))
      }

      let playback = owner.getPlayback(for: playbackInstance)
      owner.setPlayback(playback)
      resetPlaybackTimer(to: playbackInstance)

      return playback
    }

    @MainActor
    func resetPlaybackTimer(to instance: PlaybackInstance) {
      owner.playbackTask = Task { @MainActor [owner] in
        let interval = instance.pollingInterval
        for await _ in AsyncTimerSequence(interval: interval, clock: .suspending) {
          if Task.isCancelled { return }
          let playback = owner.getPlayback()
          if playback?.id == instance.id {
            if owner.playback?.time != playback?.time
              || owner.playback?.isPlaying != playback?.isPlaying
            {
              owner.setPlayback(playback)
            }
          }
        }
      }
    }

    @concurrent
    nonisolated func scrub(
      framePosition: AVAudioFramePosition,
      file: AVAudioFile,
      newInstance: PlaybackInstance,
      play: Bool,
    ) async {
      if Task.isCancelled { return }
      await owner.withEngineControlQueue { [weak owner] in
        guard let owner else { return }
        unsafe owner.player.stop()
        file.framePosition = framePosition
        unsafe owner.player.scheduleSegment(
          file,
          startingFrame: framePosition,
          frameCount: AVAudioFrameCount(file.length) - AVAudioFrameCount(framePosition),
          at: nil,
          completionCallbackType: .dataPlayedBack,
          completionHandler: { [weak owner, newInstance] _ in
            guard let owner else { return }
            PlaybackRuntime(owner: owner).cleanupPlaybackInstance(newInstance)
          },
        )
        if play {
          unsafe owner.player.play()
        }
      }
    }

    @MainActor
    func scrub(
      to time: TimeInterval,
      updatePlaybackTimer: Bool = true,
    ) throws(AIOEngine.AIOError) -> AIOEngine.Playback? {
      if let initialInstance = owner.playbackState[locked: \.playbackInstance] {
        let playback = owner.getPlayback(for: initialInstance)
        let file = initialInstance.file
        guard playback.duration > time, time >= 0 else {
          throw AIOEngine.AIOError.invalidScrubTime(details: time)
        }
        let framePosition = AVAudioFramePosition(time * file.processingFormat.sampleRate)
        let newInstance = PlaybackInstance(
          id: .init(),
          file: file,
          startFrame: framePosition,
          pollingInterval: initialInstance.pollingInterval,
        )
        owner.playbackState[locked: \.playbackInstance] = newInstance
        owner.scrubTask = Task(priority: .utility) { [weak owner] in
          guard let owner else { return }
          await PlaybackRuntime(owner: owner).scrub(
            framePosition: framePosition,
            file: file,
            newInstance: newInstance,
            play: playback.isPlaying,
          )
        }

        let newPlayback = AIOEngine.Playback(
          id: newInstance.id,
          file: file.url,
          isPlaying: playback.isPlaying,
          time: time,
          duration: playback.duration,
        )
        defer { owner.setPlayback(newPlayback) }
        if updatePlaybackTimer {
          resetPlaybackTimer(to: newInstance)
        } else {
          owner.playbackTask = nil
        }
        return newPlayback
      } else {
        return nil
      }
    }

    @MainActor
    func stopPlayback() async {
      await owner.withEngineControlQueue { [weak owner] in
        guard let owner else { return }
        unsafe owner.player.stop()
        unsafe owner.engine.stop()
        unsafe owner.engine.reset()
        if unsafe !owner.engine.attachedNodes.contains(owner.player) {
          unsafe owner.engine.attach(owner.player)
        }
      }
      let finishedFile: AVAudioFile? = owner.playbackState {
        if let foundInstance = $0.playbackInstance {
          $0.playbackInstance = nil
          return foundInstance.file
        } else {
          return nil
        }
      }
      finishedFile?.close()
      owner.playbackTask = nil
      owner.scrubTask = nil
      owner.playbackState[locked: \.playbackInstance] = nil
      owner.setPlayback(nil)
      owner.deactivateAudioSessionIfNeeded(reason: "playback stopped")
    }

    @MainActor
    func pausePlayback() {
      guard owner.isPlayback else { return }
      owner.engineControlQueue.async { [weak owner] in
        unsafe owner?.player.pause()
      }
      owner.scrubTask = nil
      if let instance = owner.playbackState[locked: \.playbackInstance] {
        owner.setPlayback(owner.getPlayback(for: instance))
      }
    }

    @MainActor
    func resumePlayback() {
      guard owner.isPlayback, unsafe !owner.player.isPlaying else { return }
      owner.engineControlQueue.async { [weak owner] in
        unsafe owner?.player.play()
      }
      if let instance = owner.playbackState[locked: \.playbackInstance] {
        owner.setPlayback(owner.getPlayback(for: instance))
      }
    }

    nonisolated func cleanupPlaybackInstance(_ instance: PlaybackInstance) {
      let finishedFile: AVAudioFile? = owner.playbackState.withLock { state in
        if let foundInstance = state.playbackInstance, foundInstance.id == instance.id {
          state.playbackInstance = nil
          return foundInstance.file
        } else {
          return nil
        }
      }
      if let finishedFile {
        owner.engineControlQueue.async { [weak owner] in
          guard let owner else { return }
          guard owner.playbackState[locked: \.playbackInstance] == nil else { return }
          unsafe owner.player.stop()
          unsafe owner.engine.stop()
          unsafe owner.engine.reset()
          if unsafe !owner.engine.attachedNodes.contains(owner.player) {
            unsafe owner.engine.attach(owner.player)
          }
        }
        Task { @MainActor [owner] in
          if owner.playbackState[locked: \.playbackInstance] == nil {
            owner.setPlayback(nil)
            owner.deactivateAudioSessionIfNeeded(reason: "playback finished")
          }
        }
        finishedFile.close()
      }
    }

    nonisolated func stopPlayerIfNeeded() async {
      await owner.withEngineControlQueue { [weak owner] in
        guard let owner, unsafe owner.player.isPlaying else { return }
        unsafe owner.player.stop()
      }
    }

    @MainActor
    func setPlaybackMixerAmplitude(_ amplitude: Float) {
      // Write directly to the mixer's output volume. Safe to call at any
      // cadence; AVAudioMixerNode.outputVolume is thread-safe for writes.
      unsafe owner.engine.mainMixerNode.outputVolume = amplitude
    }

    @MainActor
    func capturePlaybackResumeState() -> PlaybackResume? {
      guard let instance = owner.playbackState[locked: \.playbackInstance] else { return nil }
      let playback = owner.getPlayback(for: instance)
      let time =
        playback.time
        ?? (Double(instance.startFrame) / instance.file.processingFormat.sampleRate)

      return PlaybackResume(
        fileURL: instance.file.url,
        time: time,
        duration: playback.duration,
        wasPlaying: playback.isPlaying,
        pollingInterval: instance.pollingInterval,
      )
    }

    @MainActor
    func restartPlayback(from resume: PlaybackResume) async {
      let duration = resume.duration
      let clampedTime = min(max(0, resume.time), max(0, duration - 0.001))
      guard duration > clampedTime else { return }

      do {
        _ = try await playSegment(
          url: resume.fileURL,
          startTime: clampedTime,
          endTime: duration,
          onComplete: nil,
          playbackPollingInterval: resume.pollingInterval,
        )
        if resume.wasPlaying == false {
          pausePlayback()
        }
      } catch {
        log.error(
          "Failed to resume playback after media services reset: \(error, privacy: .public)",
        )
      }
    }
  }
#endif
