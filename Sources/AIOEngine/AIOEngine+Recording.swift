#if canImport(AVFoundation)
  import AVFoundation
  import AsyncAlgorithms
  import Atomics
  public import Foundation
  import os
  import Tools

  private let log = SystemLog.make()

  extension AIOEngine {

    // MARK: - Recording State Management

    /// Sets the desired recording state and attempts to reconcile it with the actual state.
    ///
    /// This method manages the recording lifecycle with automatic retry logic.
    /// When requesting to start recording, the engine will repeatedly attempt
    /// to warm up and start until either:
    /// - Recording starts successfully
    /// - The reconciliation timeout expires
    /// - A non-transient error occurs
    ///
    /// When requesting to stop recording, the engine stops immediately.
    ///
    /// - Parameters:
    ///   - desiredState: Whether recording should be active.
    ///   - configuration: The recording configuration to use when starting.
    ///                    Required when `desiredState` is `true`.
    @MainActor
    public func setDesiredRecordingState(
      _ desiredState: Bool,
      configuration: RecordingConfiguration? = nil
    ) {
      wantsRecording = desiredState
      lastRecordingStartFailure = nil
      reconciliationTask = nil

      if desiredState {
        guard let configuration else {
          log.error("Cannot start recording without configuration")
          wantsRecording = false
          return
        }
        lastRecordingConfiguration = configuration
        reconciliationTask = Task { @MainActor [weak self] in
          await self?.reconcileRecordingState(desiredState: true, configuration: configuration)
        }
      } else {
        // Stop immediately
        if isRecording {
          Task { @MainActor [weak self] in
            _ = try? await self?.stopRecording()
          }
        }
      }
    }

    /// Starts recording with automatic reconciliation and returns when complete.
    ///
    /// This is a convenience method that combines setting the desired state and
    /// waiting for reconciliation to complete. Use this when you need to know
    /// whether recording started successfully.
    ///
    /// - Parameter configuration: The recording configuration to use.
    /// - Returns: `true` if recording started successfully, `false` if reconciliation
    ///            failed after the timeout period or a non-transient error occurred.
    @MainActor
    public func startRecordingWithReconciliation(
      configuration: RecordingConfiguration
    ) async -> Bool {
      wantsRecording = true
      lastRecordingStartFailure = nil
      reconciliationTask = nil
      lastRecordingConfiguration = configuration
      await reconcileRecordingState(desiredState: true, configuration: configuration)
      return isRecording
    }

    /// Stops recording.
    ///
    /// This is a convenience method that sets the desired state to false
    /// and waits for the recording to stop.
    ///
    /// - Returns: The URL of the recorded file, or `nil` if not recording.
    @MainActor
    public func stopRecordingWithReconciliation() async -> URL? {
      wantsRecording = false
      reconciliationTask = nil
      guard isRecording else { return nil }
      return try? await stopRecording()
    }

    /// Attempts to reconcile the desired recording state with the actual state.
    @MainActor
    func reconcileRecordingState(
      desiredState: Bool,
      configuration: RecordingConfiguration
    ) async {
      guard desiredState else { return }

      let startTime = ContinuousClock.now
      let timeout = reconciliationConfiguration.timeout
      let retryInterval = reconciliationConfiguration.retryInterval

      log.info(
        "Starting recording reconciliation (timeout: \(timeout, privacy: .public), interval: \(retryInterval, privacy: .public))"
      )

      var lastError: AIOError?

      while !Task.isCancelled && wantsRecording {
        let elapsed = ContinuousClock.now - startTime

        // Check if we've exceeded the timeout
        if elapsed >= timeout {
          log.warning(
            "Recording reconciliation timed out after \(elapsed, privacy: .public)"
          )
          break
        }

        do {
          // Attempt to start recording
          try await startRecording(configuration: configuration)

          // Success!
          log.info("Recording started successfully after \(elapsed, privacy: .public)")
          lastRecordingStartFailure = nil
          return
        } catch let error where error.isTransient {
          // Transient error - wait and retry
          lastError = error
          lastRecordingStartFailure = error
          log.info(
            "Transient error during reconciliation: \(error, privacy: .public), retrying..."
          )
          try? await Task.sleep(for: retryInterval)
          continue
        } catch let error {
          // Non-transient error - give up immediately
          log.error(
            "Non-transient error during reconciliation: \(error, privacy: .public)"
          )
          lastError = error
          lastRecordingStartFailure = error
          break
        }
      }

      // Reconciliation failed - reset desired state to match actual
      if wantsRecording && !isRecording {
        log.warning(
          "Reconciliation failed, resetting wantsRecording to false. Last error: \(lastError?.localizedDescription ?? "none", privacy: .public)"
        )
        wantsRecording = false
        onReconciliationFailed?(true)
      }
    }

    /// Starts recording audio with the specified configuration.
    ///
    /// This method first stops any active playback and then warms up the engine with the provided configuration.
    /// Once the engine is ready, it starts recording audio to a temporary file.
    ///
    /// - Parameter configuration: The configuration to use for recording.
    /// - Throws: An `AIOError` if the recording configuration is invalid or if the engine fails to start.
    public nonisolated func startRecording(
      configuration: RecordingConfiguration
    ) async throws(AIOError) {
      do {
        let shouldStopPlayer = await withEngineControlQueue { [weak self] in
          guard let self else { return false }
          return unsafe self.player.isPlaying
        }
        if shouldStopPlayer {
          await stopPlayerIfNeeded()
        }
        try await MainActor.run {
          // Clear any lingering playback state before recording.
          // When shouldStopPlayer is true the player was still active and
          // we already stopped it above.  But playback can also be stale after
          // natural completion — the player has stopped yet the playback
          // struct hasn't been nilled out because cleanupPlaybackInstance's
          // MainActor Task hasn't run yet.  Clearing unconditionally prevents
          // warm()'s `!isPlaying` guard from returning early on stale state.
          if shouldStopPlayer || playback != nil {
            placeState(\.playbackInstance, nil)
            playback = nil
            onPlaybackUpdated?(nil)
          }
          lastWriteFailure = nil
          lastRecordingConfiguration = configuration
          try warm(configuration: configuration)

          let (buffers, writer, url, receiverBuffers, receiverTiming) = state {
            (
              $0.audioBuffers, $0.recordingWriter, $0.recordingURL, $0.receiverBuffers,
              $0.receiverTiming
            )
          }
          guard let buffers = buffers,
            let processingFormat = configuration.processingFormat,
            let writeWriter = writer,
            let url = url
          else {
            throw AIOError.invalidRecordingConfiguration(
              details: "state after warm(configuration:) was invalid")
          }
          let startResult = runOnEngineControlQueueResult { [weak self] in
            guard let self else { return }
            try unsafe self.engine.start()
          }
          if case .failure(let error) = startResult {
            throw AIOError.engineStartFailed(error: ErrorContext(error))
          }
          let fileFormat = configuration.outputConfiguration.fileFormat.rawValue
          onRecordingStarted?(url, fileFormat)
          startFileWriteLoop(flushing: buffers, of: processingFormat, to: writeWriter)
          if let receiverBuffers, let receiverTiming {
            startReceiverLoop(
              buffers: receiverBuffers,
              timing: receiverTiming,
              processingFormat: processingFormat
            )
          }
          self.isRecording = true
        }
      } catch let error as AIOError {
        throw error
      } catch {
        throw .engineStartFailed(error: ErrorContext(error))
      }
    }

    @MainActor func startFileWriteLoop(
      flushing buffers: [SPSCRingBuffer<Float>],
      of processingFormat: AVAudioFormat,
      to writer: any RecordingFileWriter
    ) {
      let control = WriterControl()
      let localMetrics = metrics
      let (tapErrorPoll, onTapError) = makeTapErrorHandlers()
      let errorHandler: @Sendable (ErrorContext) -> Void = { [weak self] error in
        guard let self else { return }
        Task { @MainActor in
          self.recordWriteFailure(error, url: writer.fileURL)
          self.errorSubject.send(
            AIOError.audioFileFailed(operation: .write, url: writer.fileURL, error: error)
          )
          self.onRecordingFailed?()
        }
      }
      let session = WriterSession(
        id: UUID(),
        control: control,
        writer: writer,
        fileURL: writer.fileURL
      )
      writerSession = session
      let writeBufferSize = 1024
      let preAllocatedBuffer = Transferring(
        AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: AVAudioFrameCount(writeBufferSize)
        ))
      writerQueue.async { [control, localMetrics] in
        AIOEngine.writerLoopSync(
          writer: writer,
          format: processingFormat,
          audioBuffers: buffers,
          writeBuffer: preAllocatedBuffer.value,
          control: control,
          metrics: localMetrics,
          shouldCancel: { [control] in
            control.cancelRequested.load(ordering: .relaxed)
          },
          errorHandler: errorHandler,
          tapErrorPoll: tapErrorPoll,
          onTapError: onTapError
        )
      }
      log.info("📝 Writer started for \(writer.fileURL.lastPathComponent, privacy: .public)")

    }

    @MainActor func startReceiverLoop(
      buffers: [SPSCRingBuffer<Float>],
      timing: SPSCRingBuffer<TimingPacket>,
      processingFormat: AVAudioFormat
    ) {
      stopReceiverLoop()
      let control = ReceiverControl()
      let session = ReceiverSession(
        id: UUID(),
        control: control,
        buffers: buffers,
        timing: timing,
        processingFormat: processingFormat
      )
      receiverSession = session
      #if DEBUG
        let onUnderrun: @Sendable () -> Void = { [metrics] in
          metrics.receiverUnderruns.wrappingIncrement(ordering: .relaxed)
        }
        let onDrop: @Sendable () -> Void = { [metrics] in
          metrics.receiverDrops.wrappingIncrement(ordering: .relaxed)
        }
      #else
        let onUnderrun: (@Sendable () -> Void)? = nil
        let onDrop: (@Sendable () -> Void)? = nil
      #endif
      let (tapErrorPoll, onTapError) = makeTapErrorHandlers()
      let cadence = receiverPollingInterval
      receiverQueue.async { [control, buffers, timing, processingFormat, bufferReceivers] in
        AIOEngine.receiverLoopSync(
          buffers: buffers,
          timing: timing,
          processingFormat: processingFormat,
          bufferReceivers: bufferReceivers,
          control: control,
          cadence: cadence,
          onUnderrun: onUnderrun,
          onDrop: onDrop,
          tapErrorPoll: tapErrorPoll,
          onTapError: onTapError
        )
      }
    }

    @MainActor func stopReceiverLoop() {
      guard let session = receiverSession else { return }
      session.control.cancelRequested.store(true, ordering: .relaxed)
      receiverSession = nil
    }

    @MainActor
    func prepareDrain(for session: WriterSession, targetSampleTime: Int64, logBuffers: Bool) {
      session.control.stopRequested.store(true, ordering: .relaxed)
      session.control.targetSampleTime.store(targetSampleTime, ordering: .relaxed)
      let written = session.control.writtenSampleTime.load(ordering: .relaxed)
      if written >= targetSampleTime {
        Task { await session.control.targetSatisfiedSignal.signal() }
      }
      if logBuffers {
        let counts = state.withLock { $0.audioBuffers?.map { $0.availableToRead } ?? [] }
        log.info(
          "🧹 Stop target set: target=\(targetSampleTime, privacy: .public) written=\(written, privacy: .public) buffers=\(counts, privacy: .public)"
        )
      } else {
        log.info(
          "🧹 Stop target set: target=\(targetSampleTime, privacy: .public) (non-current session)"
        )
      }
    }

    @MainActor
    func drainWriterSession(_ session: WriterSession, notifyOnFailure: Bool) async {
      let start = clock.now
      log.info("🧹 Drain start for \(session.fileURL.lastPathComponent, privacy: .public)")
      let outcome = await awaitWriterDrainOutcome(session)
      let elapsed = start.duration(to: clock.now)
      switch outcome {
      case .signaled:
        session.writer.close()
        let size = fileSizeDescription(for: session.fileURL)
        log.info(
          "🧹 Writer drained for \(session.fileURL.lastPathComponent, privacy: .public) (size=\(size, privacy: .public), elapsed=\(elapsed, privacy: .public))"
        )
      case .targetSatisfied:
        session.control.cancelRequested.store(true, ordering: .relaxed)
        session.writer.close()
        let target = session.control.targetSampleTime.load(ordering: .relaxed)
        let written = session.control.writtenSampleTime.load(ordering: .relaxed)
        log.info(
          "🧹 Drain short-circuit: target satisfied for \(session.fileURL.lastPathComponent, privacy: .public) target=\(target, privacy: .public) written=\(written, privacy: .public) elapsed=\(elapsed, privacy: .public)"
        )
      case .timedOut:
        let error = WriterDrainTimeoutError(url: session.fileURL, timeout: writerDrainTimeout)
        session.control.cancelRequested.store(true, ordering: .relaxed)
        session.writer.close()
        let target = session.control.targetSampleTime.load(ordering: .relaxed)
        let written = session.control.writtenSampleTime.load(ordering: .relaxed)
        log.error(
          "⏱️ Writer drain timed out for \(session.fileURL.lastPathComponent, privacy: .public) after \(elapsed, privacy: .public): \(error, privacy: .public) target=\(target, privacy: .public) written=\(written, privacy: .public)"
        )
        recordWriteFailure(ErrorContext(error), url: session.fileURL)
        if notifyOnFailure {
          errorSubject.send(
            AIOError.audioFileFailed(
              operation: .write,
              url: session.fileURL,
              error: ErrorContext(error)
            )
          )
          onRecordingFailed?()
        }
      }
    }

    @MainActor
    func enqueueDrain(for session: WriterSession) {
      let target = recordingSampleTimeAtomic.load(ordering: .relaxed)
      prepareDrain(
        for: session, targetSampleTime: target, logBuffers: session.id == writerSession?.id)
      drainingWriterSessions.append(session)
      Task { [weak self] in
        guard let self else { return }
        await self.drainWriterSession(session, notifyOnFailure: true)
        await MainActor.run { self.drainingWriterSessions.removeAll { $0.id == session.id } }
      }
    }

    @MainActor
    func stopAndDrainAllWriterSessions(notifyOnFailure: Bool) async {
      if Task.isCancelled {
        log.warning("🧹 stopAndDrainAllWriterSessions cancelled before start")
        return
      }
      var sessions: [WriterSession] = []
      if let current = writerSession {
        sessions.append(current)
      }
      sessions.append(contentsOf: drainingWriterSessions)

      let target = recordingSampleTimeAtomic.load(ordering: .relaxed)
      for session in sessions {
        if Task.isCancelled {
          log.warning("🧹 stopAndDrainAllWriterSessions cancelled before stop request")
          return
        }
        log.info(
          "🧹 Stop requested for writer \(session.fileURL.lastPathComponent, privacy: .public)")
        prepareDrain(
          for: session, targetSampleTime: target, logBuffers: session.id == writerSession?.id)
      }
      for session in sessions {
        if Task.isCancelled {
          log.warning("🧹 stopAndDrainAllWriterSessions cancelled before drain wait")
          return
        }
        log.info("🧹 Drain wait start for \(session.fileURL.lastPathComponent, privacy: .public)")
        await drainWriterSession(session, notifyOnFailure: notifyOnFailure)
      }

      writerSession = nil
      drainingWriterSessions.removeAll()
      log.info("🧹 stopAndDrainAllWriterSessions completed")
    }

    @MainActor
    func cancelAllWriterSessions() {
      if let current = writerSession {
        current.control.cancelRequested.store(true, ordering: .relaxed)
      }
      for session in drainingWriterSessions {
        session.control.cancelRequested.store(true, ordering: .relaxed)
      }
      writerSession = nil
      drainingWriterSessions.removeAll()
      log.info("🧹 cancelAllWriterSessions completed")
    }

    @MainActor
    func recordWriteFailure(_ error: ErrorContext, url: URL?) {
      guard lastWriteFailure == nil else { return }
      lastWriteFailure = WriteFailure(url: url, error: error)
      log.error(
        "🛑 Recording write failed for \(url?.lastPathComponent ?? "missing URL", privacy: .public): \(error, privacy: .public)"
      )
    }

    @MainActor
    func consumeWriteFailure() -> WriteFailure? {
      defer { lastWriteFailure = nil }
      return lastWriteFailure
    }

    /// Warms up the audio engine with the specified configuration.
    ///
    /// This method prepares the audio engine for recording by configuring the audio session,
    /// setting up the necessary buffers, and installing an audio tap.
    ///
    /// - Parameter configuration: The configuration to use for recording.
    /// - Throws: An `AIOError` if the configuration is invalid or if the engine fails to warm up.
    @MainActor
    public func warm(configuration: RecordingConfiguration) throws(AIOError) {
      guard !isRecording && !isPlaying else {
        return
      }
      try validateEncoderCompatibility(for: configuration)
      log.info("warming with config: \(configuration, privacy: .public)")

      if let existing = state[locked: \.recordingConfiguration] {
        if configuration == existing {
          log.info("engine already warmed")
          recordingSampleTimeAtomic.store(0, ordering: .relaxed)
          return
        } else {
          hardStop()
        }
      }

      // Reset engine to clean state unconditionally. After playback the engine
      // may have a stale graph that prevents prepare() from initialising the
      // input node correctly.
      runOnEngineControlQueue { [weak self] in
        guard let self else { return }
        unsafe self.player.stop()
        unsafe self.engine.stop()
        unsafe self.engine.reset()
        if unsafe !self.engine.attachedNodes.contains(self.player) {
          unsafe self.engine.attach(self.player)
        }
      }

      do {
        try configureAudioSession(for: configuration)

        guard let processingFormat = configuration.processingFormat else {
          throw AIOError.invalidRecordingConfiguration(details: "(processing format)")
        }

        let sampleRate = Int(processingFormat.sampleRate)
        let channelCount = Int(processingFormat.channelCount)
        guard sampleRate > 0, channelCount > 0 else {
          throw AIOError.audioSessionNotReady(
            details: "Invalid format: \(sampleRate)Hz, \(channelCount)ch"
          )
        }
        guard sampleRate < Int.max / channelCount / 2 else {
          throw AIOError.hardwareNotSupported
        }

        recordingSampleTimeAtomic.store(0, ordering: .relaxed)

        // Single call installs the tap — handles prepare(), format validation,
        // converter creation, all on the engine control queue.
        let tapResult = try reinstallTap(
          configuration: configuration,
          processingFormat: processingFormat,
          stopEngine: false
        )

        let audioBuffers = makeAudioBuffers(sampleRate: sampleRate, channelCount: channelCount)
        let receiverBuffers = makeAudioBuffers(sampleRate: sampleRate, channelCount: channelCount)
        let timingCapacity = max(
          64,
          Int(ceil(Double(sampleRate) / Double(tapResult.tapConfiguration.bufferSize))) * 4
        )
        let receiverTiming = SPSCRingBuffer<TimingPacket>(capacity: timingCapacity)

        let (url, protection): (URL, OutputFileProtection?) = try resolveOutputURL(
          for: configuration,
          allowExplicitFile: true
        )
        let writer = try makeRecordingWriter(url: url, configuration: configuration)
        applyFileProtectionIfNeeded(protection, to: url)

        state {
          $0.recordingWriter = writer
          $0.recordingURL = url
          $0.audioBuffers = audioBuffers
          $0.receiverBuffers = receiverBuffers
          $0.receiverTiming = receiverTiming
          $0.recordingConfiguration = configuration
        }
        applyTapInstallResult(tapResult, processingFormat: processingFormat)
      } catch let error as AIOError {
        log.error("Failed to warm engine: \(error, privacy: .public)")
        hardStop()
        onRecordingFailed?()
        throw error
      } catch {
        let mapped = AIOError.engineStartFailed(error: ErrorContext(error))
        log.error("Failed to warm engine: \(mapped, privacy: .public)")
        hardStop()
        onRecordingFailed?()
        throw mapped
      }
    }

    func makeAudioBuffers(
      sampleRate: Int,
      channelCount: Int
    ) -> [SPSCRingBuffer<Float>] {
      let cappedChannels = min(channelCount, 2)
      if channelCount > cappedChannels {
        log.warning(
          "Clamping channel count from \(channelCount, privacy: .public) to \(cappedChannels, privacy: .public)"
        )
      }
      let capacity = max(1, Int(Double(sampleRate) * maxBufferSeconds))
      return (0..<cappedChannels).map { _ in
        SPSCRingBuffer<Float>(capacity: capacity)
      }
    }

    @MainActor
    func validateEncoderCompatibility(
      for configuration: RecordingConfiguration
    ) throws(AIOError) {
      let fileFormat = configuration.outputConfiguration.fileFormat
      guard fileFormat == .aac || fileFormat == .adts else { return }

      let sampleRate = configuration.inputConfiguration.sampleRate.rawValue
      guard fileFormat.supportsEncodedSampleRate(sampleRate) else {
        throw AIOError.unsupportedEncodedSampleRate(
          fileFormat: fileFormat,
          sampleRate: sampleRate,
          supportedSampleRates: FileFormat.aacCompatibleSampleRates
        )
      }
    }

    @MainActor
    public func updateRecordingTapInterval(_ interval: Duration) {
      guard interval > .zero else { return }

      guard let currentConfig = state.withLock({ $0.recordingConfiguration }) else {
        lastRecordingConfiguration = lastRecordingConfiguration.map {
          RecordingConfiguration(
            inputConfiguration: $0.inputConfiguration,
            outputConfiguration: $0.outputConfiguration,
            tapInterval: interval,
            outputDestination: $0.outputDestination
          )
        }
        return
      }

      let updated = RecordingConfiguration(
        inputConfiguration: currentConfig.inputConfiguration,
        outputConfiguration: currentConfig.outputConfiguration,
        tapInterval: interval,
        outputDestination: currentConfig.outputDestination
      )

      guard updated.tapInterval != currentConfig.tapInterval else { return }

      state.withLock { $0.recordingConfiguration = updated }
      lastRecordingConfiguration = updated

      guard isRecording else { return }

      do {
        try reconfigureTapForIntervalChange(configuration: updated)
      } catch let error {
        log.warning(
          "Failed to update tap interval to \(interval, privacy: .public): \(error, privacy: .public)"
        )
      }
    }

    @MainActor
    private func reconfigureTapForIntervalChange(
      configuration: RecordingConfiguration
    ) throws(AIOError) {
      guard let processingFormat = state.withLock({ $0.tapConverterOutputFormat }) else {
        return
      }

      let result = try reinstallTap(
        configuration: configuration,
        processingFormat: processingFormat,
        stopEngine: false
      )
      applyTapInstallResult(result, processingFormat: processingFormat)

      log.info(
        "Updated tap interval to \(configuration.tapInterval, privacy: .public) (bufferSize: \(result.tapConfiguration.bufferSize, privacy: .public) frames)"
      )
    }

    /// Thread Domain: MainActor (entry point), engineControl (graph mutations).
    @MainActor func hardStop() {
      let tapBus = state.consume(\.installedTapBus)
      let busesToRemove = Array(Set([tapBus, 0].compactMap { $0 }))
      runOnEngineControlQueue { [weak self] in
        guard let self else { return }
        dispatchPrecondition(condition: .onQueue(self.engineControlQueue))
        for bus in busesToRemove {
          unsafe self.engine.inputNode.removeTap(onBus: bus)
        }
        if unsafe self.engine.isRunning {
          unsafe self.engine.stop()
        }
        if unsafe self.player.isPlaying {
          unsafe self.player.stop()
        }
        // On iOS 26.x, explicit `disconnectNodeOutput(_:)` has been observed to occasionally
        // raise an uncatchable NSException after background transitions; prefer `reset()`.
        unsafe self.engine.reset()
      }
      let hasActiveWriter = writerSession != nil || !drainingWriterSessions.isEmpty
      if let current = writerSession {
        enqueueDrain(for: current)
        writerSession = nil
      }
      cleanUp(closeFile: !hasActiveWriter)
    }

    /// Thread Domain: MainActor (entry point), engineControl (graph mutations).
    @MainActor
    func gracefulStop() async {
      log.info("gracefulStop requested")
      let tapBus = state.consume(\.installedTapBus)
      let busesToRemove = Array(Set([tapBus, 0].compactMap { $0 }))
      log.info("gracefulStop starting (tapBus=\(String(describing: tapBus), privacy: .public))")
      engineControlQueue.async { [weak self] in
        guard let self else { return }
        dispatchPrecondition(condition: .onQueue(self.engineControlQueue))
        for bus in busesToRemove {
          unsafe self.engine.inputNode.removeTap(onBus: bus)
        }
        unsafe self.engine.stop()
      }
      log.info("gracefulStop draining writer sessions")
      let drainCompleted = await withTaskGroup(of: Bool.self) { group in
        group.addTask { [self] in
          await self.stopAndDrainAllWriterSessions(notifyOnFailure: false)
          return true
        }
        group.addTask { [self] in
          try? await Task.sleep(for: self.stopDrainTimeout)
          return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
      }
      if !drainCompleted {
        let url = state[locked: \.recordingURL]
        let error = WriterDrainTimeoutError(url: url, timeout: stopDrainTimeout)
        log.error("stopAndDrainAllWriterSessions timed out: \(error, privacy: .public)")
        cancelAllWriterSessions()
        recordWriteFailure(ErrorContext(error), url: url)
      }
      cleanUp()
      isRecording = false
      wantsRecording = false
      reconciliationTask = nil
      log.info("gracefulStop completed")
      deactivateAudioSessionIfNeeded(reason: "recording stopped")
    }

    @MainActor func cleanUp(closeFile: Bool = true) {
      stopReceiverLoop()
      tapErrorCode.store(0, ordering: .relaxed)
      let writer = state { state in
        defer {
          state.recordingWriter = nil
          state.recordingURL = nil
          state.recordingConfiguration = nil
          state.audioBuffers = nil
          state.receiverBuffers = nil
          state.receiverTiming = nil
          state.tapConverter = nil
          state.tapConverterInputFormat = nil
          state.tapConverterOutputFormat = nil
          state.tapConvertedBuffer = nil
        }
        return state.recordingWriter
      }
      // Reset the cached tap snapshot so stale references are released.
      tapSnapshotLock.withLock { $0 = .empty }
      if closeFile {
        writer?.close()
      }
      playbackTask = nil
    }

    // MARK: - Thread Domain: tapCallback
    //
    // Threading model for the audio pipeline:
    // - Tap callback (processAudio): semi-RT thread managed by AVAudioEngine's
    //   internal RealtimeMessenger.mServiceQueue. Must avoid blocking locks,
    //   heap allocations, and ObjC messaging where possible. Uses
    //   withLockIfAvailable for non-blocking state access with a cached
    //   snapshot fallback.
    // - Writer loop: writerQueue (serial, .userInitiated), file I/O only.
    // - Engine control: engineControlQueue (serial, .default) for all
    //   AVAudioEngine graph mutations.
    // - Receiver loop: receiverQueue (serial, .userInitiated), visualization.
    nonisolated func processAudio(
      buffer: AVAudioPCMBuffer,
      time: AVAudioTime?,
      to processingFormat: AVAudioFormat
    ) {
      #if DEBUG
        //        tapThreadChecker.checkThread()
        let tapStart = DispatchTime.now().uptimeNanoseconds
      #endif
      let frameLength = buffer.frameLength
      guard frameLength > 0 else { return }

      // Try non-blocking lock on the main state first to get a fresh snapshot.
      // This eliminates priority inversion risk on the tap thread when the
      // MainActor or engineControlQueue holds the lock during route changes
      // or recording start/stop.
      let snapshot: TapSnapshot
      if let locked = state.withLockIfAvailable({ state in
        Transferring(
          TapSnapshot(
            audioBuffers: state.audioBuffers,
            receiverBuffers: state.receiverBuffers,
            receiverTiming: state.receiverTiming,
            converter: state.tapConverter,
            converterInputFormat: state.tapConverterInputFormat,
            converterOutputFormat: state.tapConverterOutputFormat,
            convertedBuffer: state.tapConvertedBuffer
          ))
      }) {
        snapshot = locked.value
        // Update the cached copy for future fallback reads.
        // Uses withLockIfAvailable — if the snapshot lock is contended
        // (a writer is updating), skip the cache update. The write path
        // will set the authoritative value anyway.
        tapSnapshotLock.withLockIfAvailable { $0 = locked.value }
      } else {
        // Main state lock contended — read the last-known-good snapshot
        // from the dedicated snapshot lock (nanosecond hold time).
        if let cached = tapSnapshotLock.withLockIfAvailable({ Transferring($0) }) {
          snapshot = cached.value
        } else {
          // Both locks contended simultaneously (vanishingly rare).
          // Skip this tap callback entirely rather than risk blocking.
          return
        }
      }

      let audioBuffers = snapshot.audioBuffers
      let receiverBuffers = snapshot.receiverBuffers
      let timingBuffer = snapshot.receiverTiming
      let converter = snapshot.converter
      let converterInputFormat = snapshot.converterInputFormat
      let converterOutputFormat = snapshot.converterOutputFormat
      let convertedBuffer = snapshot.convertedBuffer
      guard let converter,
        let converterInputFormat,
        let converterOutputFormat,
        formatsCompatible(converterInputFormat, buffer.format),
        formatsCompatible(converterOutputFormat, processingFormat)
      else {
        recordTapError(.converterMissing)
        return
      }

      // When the hardware sample rate differs from our processing format, the converter
      // needs enough output capacity to perform the resampling. Using the input frame
      // length here starves up/downsampling (e.g., 28kHz→48kHz) and produces distorted
      // audio. Calculate the required frames based on the sample-rate ratio instead.
      let frameRatio = processingFormat.sampleRate / buffer.format.sampleRate
      let requestedCapacity = max(
        AVAudioFrameCount(ceil(Double(frameLength) * frameRatio)),
        1
      )
      guard let convertedBuffer else {
        recordTapError(.converterMissing)
        return
      }
      guard convertedBuffer.frameCapacity >= requestedCapacity else {
        requestTapResize(frames: Int(requestedCapacity))
        recordTapError(.bufferTooSmall)
        return
      }
      convertedBuffer.frameLength = requestedCapacity

      var error: NSError? = nil
      let b = Transferring(buffer)
      let status = unsafe converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
        unsafe outStatus.pointee = .haveData
        return b.value
      }
      guard status != .error else {
        recordTapError(.conversionFailed)
        return
      }
      guard let audioBuffers else {
        return
      }

      // Enqueue to ring buffers
      let channelCount = Int(convertedBuffer.format.channelCount)
      let effectiveChannelCount = min(channelCount, audioBuffers.count)
      guard effectiveChannelCount > 0 else { return }
      if channelCount > audioBuffers.count, rtLoggingEnabled {
        log.error(
          "Channel count mismatch: \(channelCount, privacy: .public) vs \(audioBuffers.count, privacy: .public)"
        )
      }
      let convertedFrameLength = Int(convertedBuffer.frameLength)
      let writerAvailable = AIOEngine.minimumAvailableWriteFrames(
        channelCount: effectiveChannelCount,
        audioBuffers: audioBuffers,
        limit: convertedFrameLength
      )
      let writerCanWrite = writerAvailable >= convertedFrameLength
      let receiverCanWrite: Bool
      if let receiverBuffers, let timingBuffer {
        let timingHasCapacity = timingBuffer.availableToWrite >= 1
        receiverCanWrite =
          timingHasCapacity
          && AIOEngine.minimumAvailableWriteFrames(
            channelCount: effectiveChannelCount,
            audioBuffers: receiverBuffers,
            limit: convertedFrameLength
          ) >= convertedFrameLength
      } else {
        receiverCanWrite = false
      }
      #if DEBUG
        if !writerCanWrite {
          metrics.writerDrops.wrappingIncrement(by: Int64(convertedFrameLength), ordering: .relaxed)
        }
        if receiverBuffers != nil, !receiverCanWrite {
          metrics.receiverDrops.wrappingIncrement(
            by: Int64(convertedFrameLength), ordering: .relaxed)
        }
      #endif

      let processingStartSampleTime = recordingSampleTimeAtomic.load(ordering: .relaxed)
      let sourceHostTime: UInt64? =
        (time?.isHostTimeValid ?? false) ? time?.hostTime : nil
      let sourceSampleTime: Int64? =
        (time?.isSampleTimeValid ?? false) ? time.map { Int64($0.sampleTime) } : nil
      let sourceSampleRate: Double? =
        (time?.isSampleTimeValid ?? false) ? time?.sampleRate : nil
      if writerCanWrite || receiverCanWrite {
        for i in 0..<effectiveChannelCount {
          guard let channelData = unsafe convertedBuffer.floatChannelData?[i] else {
            if rtLoggingEnabled {
              log.error(
                "Failed to access channel data for channel \(i, privacy: .public)"
              )
            }
            continue
          }
          if writerCanWrite {
            unsafe audioBuffers[i].write(
              UnsafeBufferPointer(start: channelData, count: convertedFrameLength)
            )
          }
          if receiverCanWrite, let receiverBuffers, i < receiverBuffers.count {
            unsafe receiverBuffers[i].write(
              UnsafeBufferPointer(start: channelData, count: convertedFrameLength)
            )
          }
        }
      }

      if receiverCanWrite, let receiverTimingBuffer = timingBuffer {
        var packet = TimingPacket(
          startSampleTime: processingStartSampleTime,
          frameCount: convertedFrameLength,
          hostTime: sourceHostTime,
          sourceSampleTime: sourceSampleTime,
          sourceSampleRate: sourceSampleRate
        )
        _ = unsafe withUnsafePointer(to: &packet) { pointer in
          unsafe receiverTimingBuffer.write(UnsafeBufferPointer(start: pointer, count: 1))
        }
      }

      recordingSampleTimeAtomic.wrappingIncrement(
        by: Int64(convertedBuffer.frameLength),
        ordering: .relaxed
      )
      #if DEBUG
        metrics.tapCallbackCount.wrappingIncrement(ordering: .relaxed)
        let tapElapsed = DispatchTime.now().uptimeNanoseconds &- tapStart
        let previousMax = metrics.tapCallbackMaxNanos.load(ordering: .relaxed)
        if tapElapsed > previousMax {
          metrics.tapCallbackMaxNanos.store(tapElapsed, ordering: .relaxed)
        }
      #endif
    }

    nonisolated func formatsCompatible(
      _ lhs: AVAudioFormat,
      _ rhs: AVAudioFormat
    ) -> Bool {
      lhs.commonFormat == rhs.commonFormat
        && lhs.sampleRate == rhs.sampleRate
        && lhs.channelCount == rhs.channelCount
        && lhs.isInterleaved == rhs.isInterleaved
    }

    func resizeTapConvertedBufferIfNeeded() {
      let requested = consumeTapResizeRequest()
      guard requested > 0 else { return }
      let (existingCapacity, processingFormat) = state.withLock { state in
        (state.tapConvertedBuffer?.frameCapacity, state.tapConverterOutputFormat)
      }
      guard let processingFormat else { return }
      let current = Int(existingCapacity ?? 0)
      guard requested > current else { return }
      let targetCapacity = AVAudioFrameCount(requested)
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: targetCapacity
        )
      else {
        log.error(
          "Failed to resize tap buffer to \(requested, privacy: .public) frames"
        )
        return
      }
      let wrapped = state.withLock { state -> Transferring<TapSnapshot> in
        state.tapConvertedBuffer = buffer
        return Transferring(
          TapSnapshot(
            audioBuffers: state.audioBuffers,
            receiverBuffers: state.receiverBuffers,
            receiverTiming: state.receiverTiming,
            converter: state.tapConverter,
            converterInputFormat: state.tapConverterInputFormat,
            converterOutputFormat: state.tapConverterOutputFormat,
            convertedBuffer: state.tapConvertedBuffer
          ))
      }
      tapSnapshotLock.withLock { $0 = wrapped.value }
      log.warning(
        "Resized tap buffer to \(requested, privacy: .public) frames"
      )
    }

    /// Thread Domain: writerQueue
    static func writerLoopSync(
      writer: any RecordingFileWriter,
      format: AVAudioFormat,
      audioBuffers: [SPSCRingBuffer<Float>],
      writeBuffer: AVAudioPCMBuffer?,
      control: WriterControl,
      metrics: EngineMetrics,
      clock: ContinuousClock = .continuous,
      shouldCancel: @escaping @Sendable () -> Bool,
      errorHandler: @escaping @Sendable (ErrorContext) -> Void,
      tapErrorPoll: (@Sendable () -> TapErrorCode?)?,
      onTapError: (@Sendable (TapErrorCode) -> Void)?
    ) {
      #if !DEBUG
        _ = metrics
      #endif
      let bufferSize = 1024  // Write in chunks
      var stopRequestedAt: ContinuousClock.Instant?
      var lastStallLog = clock.now
      var writtenSampleTime: Int64 = 0
      var idleBackoffMillis: Double = 1

      while true {
        if shouldCancel() { break }
        if let tapErrorPoll, let onTapError, let code = tapErrorPoll() {
          onTapError(code)
        }
        let result = flushChunk(
          size: bufferSize,
          from: audioBuffers,
          in: format,
          to: writer,
          using: writeBuffer
        )
        switch result {
        case .success(let writeResult):
          let framesRead = writeResult.framesRead
          let didWrite = writeResult.writeDuration != nil
          if didWrite, framesRead > 0 {
            writtenSampleTime &+= Int64(framesRead)
            control.writtenSampleTime.store(writtenSampleTime, ordering: .relaxed)
            idleBackoffMillis = 1
          }
          let stopRequested = control.stopRequested.load(ordering: .relaxed)
          if stopRequested {
            let target = control.targetSampleTime.load(ordering: .relaxed)
            if writtenSampleTime >= target {
              Task { await control.targetSatisfiedSignal.signal() }
              break
            }
          }
          if framesRead == 0 {
            #if DEBUG
              metrics.writerUnderruns.wrappingIncrement(ordering: .relaxed)
            #endif
            if stopRequested, stopRequestedAt == nil {
              stopRequestedAt = clock.now
              log.info(
                "🧹 Writer stop requested: target=\(control.targetSampleTime.load(ordering: .relaxed), privacy: .public) written=\(writtenSampleTime, privacy: .public) file=\(writer.fileURL.lastPathComponent, privacy: .public)"
              )
            }
            if stopRequested,
              minimumAvailableFrames(
                channelCount: Int(format.channelCount),
                audioBuffers: audioBuffers,
                limit: bufferSize
              ) == 0
            {
              break
            }
            if stopRequested {
              let target = control.targetSampleTime.load(ordering: .relaxed)
              if writtenSampleTime >= target {
                Task { await control.targetSatisfiedSignal.signal() }
                break
              }
            }
            if stopRequested, let stopRequestedAt {
              let elapsed = stopRequestedAt.duration(to: clock.now)
              if elapsed > .seconds(1), lastStallLog.duration(to: clock.now) > .seconds(1) {
                lastStallLog = clock.now
                #if DEBUG
                  metrics.writerStallCount.wrappingIncrement(ordering: .relaxed)
                #endif
                let counts = audioBuffers.map { $0.availableToRead }
                let minAvail = minimumAvailableFrames(
                  channelCount: Int(format.channelCount),
                  audioBuffers: audioBuffers,
                  limit: bufferSize
                )
                log.warning(
                  "🧹 Writer stall after stop: elapsed=\(elapsed, privacy: .public) minAvail=\(minAvail, privacy: .public) counts=\(counts, privacy: .public)"
                )
              }
            }
            if shouldCancel() { break }
            let sleepMillis = stopRequested ? 1.0 : idleBackoffMillis
            Thread.sleep(forTimeInterval: sleepMillis / 1000.0)
            if !stopRequested {
              idleBackoffMillis = min(idleBackoffMillis * 2, 8)
            }
          }
        case .failure(let error):
          let context = ErrorContext(error)
          errorHandler(context)
          break
        }
      }
      log.info("🧹 writerLoop exiting for \(writer.fileURL.lastPathComponent, privacy: .public)")
      Task { await control.drainSignal.signal() }
    }
    /// Thread Domain: receiverQueue
    // swift-format-ignore
    static func receiverLoopSync(
      buffers: [SPSCRingBuffer<Float>],
      timing: SPSCRingBuffer<TimingPacket>,
      processingFormat: AVAudioFormat,
      bufferReceivers: Synchronized<[any BufferReceiver<Float>]>,
      control: ReceiverControl,
      cadence: Duration,
      onUnderrun: (@Sendable () -> Void)?,
      onDrop: (@Sendable () -> Void)?,
      tapErrorPoll: (@Sendable () -> TapErrorCode?)?,
      onTapError: (@Sendable (TapErrorCode) -> Void)?
    ) {
      let channelCount = min(Int(processingFormat.channelCount), buffers.count)
      guard channelCount > 0 else { return }

      let timingScratch = UnsafeMutableBufferPointer<TimingPacket>.allocate(capacity: 1)
      defer { unsafe timingScratch.deallocate() }

      var scratchCapacity = 0
      var scratchBuffers: [UnsafeMutableBufferPointer<Float>] = unsafe []
      func ensureScratchCapacity(_ needed: Int) {
        guard needed > scratchCapacity else { return }
        for unsafe buffer in unsafe scratchBuffers {
          unsafe buffer.baseAddress?.deallocate()
        }
        unsafe scratchBuffers = unsafe (0..<channelCount).map { _ in
          let pointer = UnsafeMutablePointer<Float>.allocate(capacity: needed)
          return unsafe UnsafeMutableBufferPointer(start: pointer, count: needed)
        }
        scratchCapacity = needed
      }
      defer {
        for unsafe buffer in unsafe scratchBuffers {
          unsafe buffer.baseAddress?.deallocate()
        }
      }

      let sleepInterval =  max(
          0.001,
          cadence / Duration.seconds(1.0)
        )

      let maxBacklog = 4
      while !control.cancelRequested.load(ordering: .relaxed) {
        if let tapErrorPoll, let onTapError, let code = tapErrorPoll() {
          onTapError(code)
        }
        var backlog = timing.availableToRead
        while backlog > maxBacklog && !control.cancelRequested.load(ordering: .relaxed) {
          let droppedTimingRead = unsafe timing.read(into: timingScratch)
          guard droppedTimingRead > 0 else { break }
          let droppedPacket = unsafe timingScratch[0]
          guard droppedPacket.frameCount > 0 else {
            backlog = timing.availableToRead
            continue
          }
          ensureScratchCapacity(droppedPacket.frameCount)
          for index in 0..<channelCount {
            let destination = unsafe UnsafeMutableBufferPointer(
              start: scratchBuffers[index].baseAddress,
              count: droppedPacket.frameCount
            )
            _ = unsafe buffers[index].read(into: destination)
          }
          onDrop?()
          backlog = timing.availableToRead
        }
        let timingRead = unsafe timing.read(into: timingScratch)
        guard timingRead > 0 else {
          Thread.sleep(forTimeInterval: sleepInterval)
          continue
        }
        let packet = unsafe timingScratch[0]
        guard packet.frameCount > 0 else { continue }

        ensureScratchCapacity(packet.frameCount)
        var actualFrames = packet.frameCount
        for index in 0..<channelCount {
          let destination = unsafe UnsafeMutableBufferPointer(
            start: scratchBuffers[index].baseAddress,
            count: packet.frameCount
          )
          let read = unsafe buffers[index].read(into: destination)
          actualFrames = min(actualFrames, read)
        }
        guard actualFrames > 0, actualFrames == packet.frameCount else {
          onUnderrun?()
          continue
        }
        guard let base = unsafe scratchBuffers.first?.baseAddress else { continue }

        let timing = BufferTiming(
          sampleTime: packet.startSampleTime,
          sampleRate: processingFormat.sampleRate,
          hostTime: packet.hostTime,
          sourceSampleTime: packet.sourceSampleTime,
          sourceSampleRate: packet.sourceSampleRate
        )
        let bufferPointer = unsafe UnsafeBufferPointer(start: base, count: actualFrames)
        bufferReceivers({ $0 }).forEach {
          unsafe $0.processBuffer(bufferPointer, timing: timing)
        }
      }
    }

    /// Thread Domain: writerQueue
    ///
    /// - Parameter reusableBuffer: A pre-allocated buffer to reuse across calls,
    ///   eliminating per-chunk `AVAudioPCMBuffer` heap allocations. If `nil`,
    ///   a new buffer is allocated (fallback for edge cases).
    static func flushChunk(
      size bufferSize: Int,
      from audioBuffers: [SPSCRingBuffer<Float>],
      in audioFormat: AVAudioFormat,
      to writer: any RecordingFileWriter,
      using reusableBuffer: AVAudioPCMBuffer? = nil,
      clock: ContinuousClock = .continuous
    ) -> Result<WriteResult, any Error> {
      let channelCount = Int(audioFormat.channelCount)
      let framesToRead = minimumAvailableFrames(
        channelCount: channelCount,
        audioBuffers: audioBuffers,
        limit: bufferSize
      )

      guard framesToRead > 0 else {
        return .success(.init(framesRead: 0, writeDuration: nil))
      }

      // Prefer the pre-allocated buffer; fall back to a fresh allocation.
      let pcmBuffer: AVAudioPCMBuffer
      if let reusableBuffer, reusableBuffer.frameCapacity >= AVAudioFrameCount(bufferSize) {
        pcmBuffer = reusableBuffer
      } else {
        guard
          let freshBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(bufferSize)
          )
        else {
          return .success(.init(framesRead: 0, writeDuration: nil))
        }
        pcmBuffer = freshBuffer
      }

      var actualFrames = framesToRead
      // Dequeue from ring buffers using a consistent frame count per channel
      for i in 0..<channelCount {
        guard let channelData = unsafe pcmBuffer.floatChannelData?[i] else {
          actualFrames = 0
          return .success(.init(framesRead: 0, writeDuration: nil))
        }
        let readSize = unsafe audioBuffers[i].read(
          into: UnsafeMutableBufferPointer(start: channelData, count: framesToRead))
        actualFrames = min(actualFrames, readSize)
      }

      guard actualFrames > 0 else {
        return .success(.init(framesRead: 0, writeDuration: nil))
      }
      pcmBuffer.frameLength = AVAudioFrameCount(actualFrames)

      do {
        let start = clock.now
        try writer.write(pcmBuffer)
        let elapsed = start.duration(to: clock.now)
        if elapsed > .milliseconds(200) {
          log.warning(
            "🐢 Slow write: \(elapsed, privacy: .public) frames=\(actualFrames, privacy: .public) file=\(writer.fileURL.lastPathComponent, privacy: .public)"
          )
        }
        return .success(.init(framesRead: actualFrames, writeDuration: elapsed))
      } catch {
        log.error("error flushing chunk: \(error, privacy: .public)")
        return .failure(error)
      }
    }

    static func minimumAvailableFrames(
      channelCount: Int,
      audioBuffers: [SPSCRingBuffer<Float>],
      limit: Int
    ) -> Int {
      guard channelCount > 0 else { return 0 }

      var minimum = limit
      for index in 0..<min(channelCount, audioBuffers.count) {
        minimum = min(minimum, audioBuffers[index].availableToRead)
        if minimum == 0 { break }
      }
      return minimum
    }

    static func minimumAvailableWriteFrames(
      channelCount: Int,
      audioBuffers: [SPSCRingBuffer<Float>],
      limit: Int
    ) -> Int {
      guard channelCount > 0 else { return 0 }

      var minimum = limit
      for index in 0..<min(channelCount, audioBuffers.count) {
        minimum = min(minimum, audioBuffers[index].availableToWrite)
        if minimum == 0 { break }
      }
      return minimum
    }

    /// Stops the current recording and returns the URL of the recorded file.
    ///
    /// - Returns: The URL of the recorded file.
    /// - Throws: An `AIOError.notRecording` error if the engine is not currently recording.
    @MainActor
    public func stopRecording() async throws(AIOError) -> URL {
      guard let url = state[locked: \.recordingURL], isRecording else {
        throw AIOError.notRecording
      }
      await gracefulStop()
      let fileExists = FileManager.default.fileExists(atPath: url.path)
      let fileSize = fileSizeValue(for: url)
      let failure = consumeWriteFailure()
      if !fileExists {
        throw AIOError.audioFileFailed(
          operation: .write,
          url: url,
          error: ErrorContext(MissingAudioFileError(url: url))
        )
      }
      if let size = fileSize, size == 0 {
        throw AIOError.audioFileFailed(
          operation: .write,
          url: url,
          error: ErrorContext(EmptyAudioFileError(url: url))
        )
      }
      if let failure {
        if isWriterDrainTimeout(failure), fileExists, (fileSize ?? 0) > 0 {
          log.warning(
            "⚠️ Writer drain timed out but file exists with data; continuing stop for \(url.lastPathComponent, privacy: .public)"
          )
        } else {
          throw AIOError.audioFileFailed(operation: .write, url: failure.url, error: failure.error)
        }
      }
      let finalSize = fileSizeDescription(for: url)
      log.info(
        "✅ Recording stopped: \(url.lastPathComponent, privacy: .public) size=\(finalSize, privacy: .public)"
      )
      onRecordingCompleted?()
      return url
    }

    nonisolated func isWriterDrainTimeout(_ failure: WriteFailure) -> Bool {
      failure.error.domain.contains("WriterDrainTimeoutError")
        || failure.error.message.localizedCaseInsensitiveContains("writer drain timed out")
    }

    /// Rotates the recording to a new file without interrupting audio capture.
    ///
    /// This method is used for segmented recording mode, where the recorder automatically
    /// creates new track files at specified intervals. The ring buffers continue receiving
    /// audio throughout the rotation - no samples are lost.
    ///
    /// The rotation process:
    /// 1. Creates a new output file
    /// 2. Cancels the current writer loop (it will flush remaining data)
    /// 3. Waits briefly for the writer to finish the current chunk
    /// 4. Updates state with the new file
    /// 5. Starts a new writer loop
    ///
    /// - Returns: URL of the completed (previous) recording file
    /// - Throws: `AIOError.notRecording` if not currently recording
    @MainActor
    public func rotateRecordingFile() async throws(AIOError) -> URL {

      guard isRecording,
        let (currentURL, configuration, format): (URL, RecordingConfiguration, AVAudioFormat) =
          state.withLock({
            guard let url = $0.recordingURL,
              let config = $0.recordingConfiguration,
              let format = config.processingFormat
            else {
              return Optional.none
            }
            return Optional((url, config, format))
          })
      else {
        throw AIOError.notRecording
      }

      // Create new file with fresh filename
      let (newURL, protection): (URL, OutputFileProtection?) = try resolveOutputURL(
        for: configuration,
        allowExplicitFile: false
      )
      let newWriter = try makeRecordingWriter(url: newURL, configuration: configuration)
      applyFileProtectionIfNeeded(protection, to: newURL)

      let sampleRate = Int(format.sampleRate)
      let channelCount = Int(format.channelCount)
      guard sampleRate > 0, channelCount > 0 else {
        throw AIOError.invalidRecordingConfiguration(details: "Invalid processing format")
      }

      let newBuffers = makeAudioBuffers(
        sampleRate: sampleRate,
        channelCount: channelCount
      )

      if let currentWriter = writerSession {
        enqueueDrain(for: currentWriter)
      } else {
        state[locked: \.recordingWriter]?.close()
      }

      // Update state with new file and refresh the cached tap snapshot so the
      // tap thread sees the new ring buffers on its next fallback read.
      let wrapped = state { state -> Transferring<TapSnapshot> in
        state.recordingWriter = newWriter
        state.recordingURL = newURL
        state.audioBuffers = newBuffers
        return Transferring(
          TapSnapshot(
            audioBuffers: state.audioBuffers,
            receiverBuffers: state.receiverBuffers,
            receiverTiming: state.receiverTiming,
            converter: state.tapConverter,
            converterInputFormat: state.tapConverterInputFormat,
            converterOutputFormat: state.tapConverterOutputFormat,
            convertedBuffer: state.tapConvertedBuffer
          ))
      }
      tapSnapshotLock.withLock { $0 = wrapped.value }

      // Start new writer loop for the new file
      startFileWriteLoop(flushing: newBuffers, of: format, to: newWriter)

      // Notify of new file (for crash detection tracking)
      let fileFormat = configuration.outputConfiguration.fileFormat.rawValue
      onRecordingStarted?(newURL, fileFormat)

      log.info("📼 Rotated recording file to: \(newURL.lastPathComponent, privacy: .public)")

      return currentURL
    }
  }
#endif
