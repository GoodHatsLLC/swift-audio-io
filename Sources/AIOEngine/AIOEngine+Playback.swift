#if canImport(AVFoundation)
  import AVFoundation
  import AsyncAlgorithms
  public import Foundation
  import os
  import SystemLog
  import Tools

  private let log = SystemLog.make()

  extension AIOEngine {

    /// Plays an audio file from the specified URL.
    ///
    /// This method stops any current playback or recording before starting the new playback.
    ///
    /// - Parameter url: The URL of the audio file to play.
    /// - Returns: A `Playback` instance representing the current playback state.
    /// - Throws: An `AIOError.cannotPlayWhileRecording` error if the engine is currently recording.
    @MainActor
    public func play(url: URL) async throws(AIOError) -> Playback {
      try await play(url: url, playbackPollingInterval: nil)
    }

    /// Plays an audio file from the specified URL.
    ///
    /// This method stops any current playback or recording before starting the new playback.
    ///
    /// - Parameters:
    ///   - url: The URL of the audio file to play.
    ///   - playbackPollingInterval: Optional override for how often `playback.time` is refreshed.
    /// - Returns: A `Playback` instance representing the current playback state.
    /// - Throws: An `AIOError.cannotPlayWhileRecording` error if the engine is currently recording.
    @MainActor
    public func play(url: URL, playbackPollingInterval: Duration?) async throws(AIOError)
      -> Playback
    {
      // Prevent playback while recording
      guard !isRecording else {
        throw AIOError.cannotPlayWhileRecording
      }

      try configureAudioSessionForPlayback()

      let file: AVAudioFile
      do {
        file = try AVAudioFile(forReading: url)
      } catch {
        throw AIOError.audioFileFailed(
          operation: .openForReading, url: url, error: ErrorContext(error))
      }
      guard file.length > 0 else {
        throw AIOError.audioFileFailed(
          operation: .openForReading,
          url: url,
          error: ErrorContext(EmptyAudioFileError(url: url))
        )
      }
      let interval =
        (playbackPollingInterval ?? defaultPlaybackPollingInterval) > .zero
        ? (playbackPollingInterval ?? defaultPlaybackPollingInterval)
        : .seconds(0.5)
      let playbackInstance = PlaybackInstance(
        id: .init(),
        file: file,
        startFrame: file.framePosition,
        pollingInterval: interval
      )

      // Clear any existing playback state before starting new playback.
      if getPlayback() != nil {
        state[locked: \.playbackInstance] = nil
        setPlayback(nil)
      }
      state[locked: \.playbackInstance] = playbackInstance

      // Perform all engine graph mutations in a single engineControlQueue dispatch
      // to prevent route-change interleaving between suspension points.
      let startResult = await withEngineControlQueueResult { [weak self] in
        guard let self else { return }
        // Reset engine state
        unsafe self.player.stop()
        unsafe self.engine.stop()
        unsafe self.engine.reset()
        if unsafe !self.engine.attachedNodes.contains(self.player) {
          unsafe self.engine.attach(self.player)
        }
        // Connect the player node through the main mixer for automatic format conversion.
        // Connecting directly to outputNode can raise an uncatchable NSException on iOS 26.x
        // when the file's processingFormat doesn't match the hardware output format.
        unsafe self.engine.connect(
          self.player,
          to: self.engine.mainMixerNode,
          format: file.processingFormat
        )
        unsafe self.player
          .scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) {
            [
              weak self,
              playbackInstance
            ] _ in
            self?.cleanupPlaybackInstance(playbackInstance)
          }
        try unsafe self.engine.start()
        unsafe self.player.play()
      }
      if case .failure(let error) = startResult {
        throw AIOError.engineStartFailed(error: ErrorContext(error))
      }
      let playback = getPlayback(for: playbackInstance)
      setPlayback(playback)
      resetPlaybackTimer(to: playbackInstance)
      return playback
    }

    /// Plays a specific segment (time range) of an audio file.
    ///
    /// Use this for non-destructive audio editing playback, where segments of the
    /// original file are played in sequence.
    ///
    /// - Parameters:
    ///   - url: The URL of the audio file.
    ///   - startTime: Start time in seconds within the file.
    ///   - endTime: End time in seconds within the file.
    ///   - onComplete: Called when the segment finishes playing (on main actor).
    /// - Returns: A `Playback` instance representing the segment playback state.
    /// - Throws: An `AIOError.cannotPlayWhileRecording` error if currently recording.
    @MainActor
    public func playSegment(
      url: URL,
      startTime: TimeInterval,
      endTime: TimeInterval,
      onComplete: (@MainActor @Sendable () -> Void)? = nil,
      playbackPollingInterval: Duration? = nil
    ) async throws(AIOError) -> Playback {
      guard !isRecording else {
        throw AIOError.cannotPlayWhileRecording
      }

      try configureAudioSessionForPlayback()

      let file: AVAudioFile
      do {
        file = try AVAudioFile(forReading: url)
      } catch {
        throw AIOError.audioFileFailed(
          operation: .openForReading, url: url, error: ErrorContext(error))
      }
      let sampleRate = file.processingFormat.sampleRate
      let startFrame = AVAudioFramePosition(startTime * sampleRate)
      let duration = endTime - startTime
      let frameCount = AVAudioFrameCount(duration * sampleRate)

      // Validate frame range
      guard startFrame >= 0, frameCount > 0,
        AVAudioFramePosition(startFrame) + AVAudioFramePosition(frameCount) <= file.length
      else {
        throw AIOError.invalidTimeRange
      }

      let interval =
        (playbackPollingInterval ?? defaultPlaybackPollingInterval) > .zero
        ? (playbackPollingInterval ?? defaultPlaybackPollingInterval)
        : .seconds(0.5)
      let playbackInstance = PlaybackInstance(
        id: .init(),
        file: file,
        startFrame: startFrame,
        pollingInterval: interval
      )

      // Clear any existing playback state before starting new playback.
      if getPlayback() != nil {
        state[locked: \.playbackInstance] = nil
        setPlayback(nil)
      }
      state[locked: \.playbackInstance] = playbackInstance

      // Perform all engine graph mutations in a single engineControlQueue dispatch
      // to prevent route-change interleaving between suspension points.
      let startResult = await withEngineControlQueueResult { [weak self] in
        guard let self else { return }
        // Reset engine state
        unsafe self.player.stop()
        unsafe self.engine.stop()
        unsafe self.engine.reset()
        if unsafe !self.engine.attachedNodes.contains(self.player) {
          unsafe self.engine.attach(self.player)
        }
        unsafe self.engine.connect(
          self.player,
          to: self.engine.mainMixerNode,
          format: file.processingFormat
        )
        unsafe self.player.scheduleSegment(
          file,
          startingFrame: startFrame,
          frameCount: frameCount,
          at: nil,
          completionCallbackType: .dataPlayedBack
        ) { [weak self, playbackInstance] _ in
          self?.cleanupPlaybackInstance(playbackInstance)
          if let onComplete {
            Task { @MainActor in
              onComplete()
            }
          }
        }
        try unsafe self.engine.start()
        unsafe self.player.play()
      }
      if case .failure(let error) = startResult {
        throw AIOError.engineStartFailed(error: ErrorContext(error))
      }

      let playback = getPlayback(for: playbackInstance)
      setPlayback(playback)
      resetPlaybackTimer(to: playbackInstance)

      return playback
    }

    @MainActor func resetPlaybackTimer(to instance: PlaybackInstance) {
      playbackTask = Task { @MainActor in
        let interval = instance.pollingInterval
        for await _ in AsyncTimerSequence(interval: interval, clock: .suspending) {
          if Task.isCancelled { return }
          let p = getPlayback()
          if p?.id == instance.id {
            // Only update if state meaningfully changed to avoid triggering
            // unnecessary SwiftUI observation updates
            if playback?.time != p?.time || playback?.isPlaying != p?.isPlaying {
              setPlayback(p)
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
      play: Bool
    ) async {
      if Task.isCancelled { return }
      await withEngineControlQueue { [weak self] in
        guard let self else { return }
        unsafe self.player.stop()
        file.framePosition = framePosition
        unsafe self.player
          .scheduleSegment(
            file,
            startingFrame: framePosition,
            frameCount: AVAudioFrameCount(file.length) - AVAudioFrameCount(framePosition),
            at: nil,
            completionCallbackType: .dataPlayedBack,
            completionHandler: { [weak self, newInstance] _ in
              self?.cleanupPlaybackInstance(newInstance)
            }
          )
        if play {
          unsafe self.player.play()
        }
      }
    }

    @MainActor
    public func scrub(
      to time: TimeInterval,
      updatePlaybackTimer: Bool = true
    ) throws(AIOError) -> Playback? {
      if let initialInstance = state[locked: \.playbackInstance] {
        let playback = getPlayback(for: initialInstance)
        let file = initialInstance.file
        guard playback.duration > time, time >= 0 else {
          throw AIOError.invalidScrubTime(details: time)
        }
        let framePosition = AVAudioFramePosition(time * file.processingFormat.sampleRate)
        let newInstance = PlaybackInstance(
          id: .init(),
          file: file,
          startFrame: framePosition,
          pollingInterval: initialInstance.pollingInterval
        )
        state[locked: \.playbackInstance] = newInstance
        scrubTask = Task(priority: .utility) { [weak self] in
          guard let self else { return }
          await self.scrub(
            framePosition: framePosition,
            file: file,
            newInstance: newInstance,
            play: playback.isPlaying
          )
        }

        let newPlayback = Playback(
          id: newInstance.id,
          file: file.url,
          isPlaying: playback.isPlaying,
          time: time,
          duration: playback.duration
        )
        defer { setPlayback(newPlayback) }
        if updatePlaybackTimer {
          resetPlaybackTimer(to: newInstance)
        } else {
          playbackTask = nil
        }
        return newPlayback
      } else {
        return nil
      }
    }

    /// Stops the current playback.
    @MainActor
    public func stopPlayback() async {
      // Stop the player AND the engine, then reset the graph so the engine
      // is left in a clean idle state.  Previously only the player was
      // stopped, leaving the engine running with a playback-only graph
      // (player → mainMixerNode) where the input node has sampleRate: 0.
      // If deactivateAudioSessionOnStop was true, the session could be
      // deactivated while the engine was still running, further confusing
      // subsequent recording warm-up.
      await withEngineControlQueue { [weak self] in
        guard let self else { return }
        unsafe self.player.stop()
        unsafe self.engine.stop()
        unsafe self.engine.reset()
        if unsafe !self.engine.attachedNodes.contains(self.player) {
          unsafe self.engine.attach(self.player)
        }
      }
      let finishedFile: AVAudioFile? = state {
        if let foundInstance = $0.playbackInstance {
          $0.playbackInstance = nil
          return foundInstance.file
        } else {
          return nil
        }
      }
      finishedFile?.close()
      playbackTask = nil
      scrubTask = nil
      placeState(\.playbackInstance, nil)
      playback = nil
      onPlaybackUpdated?(nil)
      deactivateAudioSessionIfNeeded(reason: "playback stopped")
    }

    /// Pauses the current playback without stopping it.
    ///
    /// The playback can be resumed with ``resumePlayback()``.
    /// Unlike ``stopPlayback()``, this keeps the playback state intact.
    @MainActor
    public func pausePlayback() {
      guard isPlayback else { return }
      engineControlQueue.async { [weak self] in
        unsafe self?.player.pause()
      }
      scrubTask = nil
      // Update the playback state to reflect paused status
      if let instance = state[locked: \.playbackInstance] {
        setPlayback(getPlayback(for: instance))
      }
    }

    /// Resumes a paused playback.
    ///
    /// Has no effect if playback is not paused or if there is no active playback.
    @MainActor
    public func resumePlayback() {
      guard isPlayback, unsafe !player.isPlaying else { return }
      engineControlQueue.async { [weak self] in
        unsafe self?.player.play()
      }
      // Update the playback state to reflect playing status
      if let instance = state[locked: \.playbackInstance] {
        setPlayback(getPlayback(for: instance))
      }
    }

    nonisolated func cleanupPlaybackInstance(_ instance: PlaybackInstance) {
      let finishedFile: AVAudioFile? = state.withLock { state in
        if let foundInstance = state.playbackInstance, foundInstance.id == instance.id {
          state.playbackInstance = nil
          return foundInstance.file
        } else {
          return nil
        }
      }
      if let finishedFile {
        // Stop the engine now that playback has finished.  Dispatched
        // asynchronously on the serial engine control queue so any
        // subsequent recording warm-up or new playback start (which also
        // dispatch to this queue) will see a clean, idle engine.
        engineControlQueue.async { [weak self] in
          guard let self else { return }
          // Only tear down if no new playback instance started meanwhile.
          guard self.state[locked: \.playbackInstance] == nil else { return }
          unsafe self.player.stop()
          unsafe self.engine.stop()
          unsafe self.engine.reset()
          if unsafe !self.engine.attachedNodes.contains(self.player) {
            unsafe self.engine.attach(self.player)
          }
        }
        Task { @MainActor [weak self, state] in
          if state[locked: \.playbackInstance] == nil {
            self?.setPlayback(nil)
            self?.deactivateAudioSessionIfNeeded(reason: "playback finished")
          }
        }
        finishedFile.close()
      }
    }

    nonisolated func stopPlayerIfNeeded() async {
      await withEngineControlQueue { [weak self] in
        guard let self, unsafe self.player.isPlaying else { return }
        unsafe self.player.stop()
      }
    }

    @MainActor
    func capturePlaybackResumeState() -> PlaybackResume? {
      guard let instance = state[locked: \.playbackInstance] else { return nil }
      let playback = getPlayback(for: instance)
      let time =
        playback.time
        ?? (Double(instance.startFrame) / instance.file.processingFormat.sampleRate)

      return PlaybackResume(
        fileURL: instance.file.url,
        time: time,
        duration: playback.duration,
        wasPlaying: playback.isPlaying,
        pollingInterval: instance.pollingInterval
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
          playbackPollingInterval: resume.pollingInterval
        )
        if resume.wasPlaying == false {
          pausePlayback()
        }
      } catch {
        log.error(
          "Failed to resume playback after media services reset: \(error, privacy: .public)")
      }
    }
  }
#endif
