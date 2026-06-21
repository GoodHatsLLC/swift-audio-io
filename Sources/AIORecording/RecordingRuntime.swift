// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOSupport
  import AIOEngineCore
  import AIORecordingSupport
  import AVFoundation
  import Foundation
  import os
  import Tools

  private let log = SystemLog.make()

  extension AIOEngine {
    var recordingRuntime: RecordingRuntime {
      RecordingRuntime(owner: self)
    }
  }

  struct RecordingRuntime {
    let owner: AIOEngine

    @MainActor
    func setDesiredRecordingState(
      _ desiredState: Bool,
      configuration: RecordingConfiguration? = nil,
    ) {
      owner.wantsRecording = desiredState
      owner.lastRecordingStartFailure = nil
      owner.reconciliationTask = nil

      if desiredState {
        guard let configuration else {
          log.error("Cannot start recording without configuration")
          owner.wantsRecording = false
          return
        }
        owner.lastRecordingConfiguration = configuration
        owner.reconciliationTask = MainActorOwnedWork { [weak owner] in
          guard let owner else { return }
          await RecordingRuntime(owner: owner).reconcileRecordingState(
            desiredState: true,
            configuration: configuration,
          )
        }
      } else if owner.isStartingRecording {
        // A stop requested mid-bring-up cannot tear down the half-built engine
        // inline, and `isRecording` is still `false`, so the usual stop task
        // would be a no-op and the stop would be silently lost. Record the abort;
        // the start path's PUBLISH-hop reconcile performs the `gracefulStop()`.
        // This is a user stop, so no `recordingFailed` event is emitted.
        owner.startAbortRequested = true
        return
      } else if owner.isRecording {
        owner.reconciliationTask = MainActorOwnedWork { [weak owner] in
          guard let owner else { return }
          _ = try? await RecordingRuntime(owner: owner).stopRecording()
        }
      }
    }

    @MainActor
    func startRecordingWithReconciliation(
      configuration: RecordingConfiguration,
    ) async -> Bool {
      owner.wantsRecording = true
      owner.lastRecordingStartFailure = nil
      owner.reconciliationTask = nil
      owner.lastRecordingConfiguration = configuration
      await reconcileRecordingState(desiredState: true, configuration: configuration)
      return owner.isRecording
    }

    @MainActor
    func reconcileRecordingState(
      desiredState: Bool,
      configuration: RecordingConfiguration,
    ) async {
      guard desiredState else { return }

      let startTime = ContinuousClock.now
      let timeout = owner.reconciliationConfiguration.timeout
      let retryInterval = owner.reconciliationConfiguration.retryInterval
      let retryPolicy = RetryPolicy(maxAttempts: .max, delay: .constant(retryInterval))

      log.info(
        "Starting recording reconciliation (timeout: \(timeout, privacy: .public), interval: \(retryInterval, privacy: .public))",
      )

      var lastError: RecordingError?

      while !Task.isCancelled, owner.wantsRecording {
        let elapsed = ContinuousClock.now - startTime

        if elapsed >= timeout {
          log.warning(
            "Recording reconciliation timed out after \(elapsed, privacy: .public)",
          )
          break
        }

        do {
          _ = try await startRecording(configuration: configuration)
          log.info("Recording started successfully after \(elapsed, privacy: .public)")
          owner.lastRecordingStartFailure = nil
          return
        } catch let error where error.isTransient {
          lastError = error
          owner.lastRecordingStartFailure = error
          log.info(
            "Transient error during reconciliation: \(error, privacy: .public), retrying...",
          )
          try? await retryPolicy.wait(afterFailureCount: 1)
          continue
        } catch {
          log.error(
            "Non-transient error during reconciliation: \(error, privacy: .public)",
          )
          lastError = error
          owner.lastRecordingStartFailure = error
          break
        }
      }

      if owner.wantsRecording, !owner.isRecording {
        log.warning(
          "Reconciliation failed, resetting wantsRecording to false. Last error: \(lastError?.localizedDescription ?? "none", privacy: .public)",
        )
        owner.wantsRecording = false
        owner.eventSubject.send(AudioIOEvent.reconciliationFailed(desiredRecording: true))
      }
    }

    nonisolated func startRecording(
      configuration: RecordingConfiguration,
    ) async throws(RecordingError) -> URL {
      do {
        // (a) Stop any active player on the engine-control queue (unchanged).
        let shouldStopPlayer = await owner.withEngineControlQueue { [weak owner] in
          guard let owner else { return false }
          return unsafe owner.player.isPlaying
        }
        if shouldStopPlayer {
          await owner.withEngineControlQueue { [weak owner] in
            guard let owner, unsafe owner.player.isPlaying else { return }
            unsafe owner.player.stop()
          }
        }

        // (b) MainActor PREP hop: publish main-isolated teardown/state changes and
        // capture the values the off-main warm path needs.
        let inputs: RecordingEngineRuntime.WarmInputs = try await MainActor.run {
          if shouldStopPlayer || owner.playback != nil {
            owner.playbackState[locked: \.playbackInstance] = nil
            owner.setPlayback(nil)
          }
          owner.lastWriteFailure = nil
          owner.lastRecordingConfiguration = configuration

          // If a *different* configuration is already warmed, tear it down here on
          // the main actor so the nonisolated warm core never needs `hardStop()`.
          if let existing = owner.state[locked: \.recordingConfiguration],
            existing != configuration
          {
            owner.hardStop()
          }

          let alreadyActive = owner.isRecording || owner.isPlaying

          // Activate the `@MainActor` audio-session delegate here (it cannot run on
          // the off-main warm path). Skipped when already active, mirroring the
          // early-return guard in `performWarm`.
          if !alreadyActive {
            do throws(SessionError) {
              try owner.activateAudioSessionDelegate(owner.audioSessionDelegate)
            } catch {
              throw RecordingError.session(error)
            }
          }

          // Open the bring-up window only AFTER the fallible main-actor prep
          // (delegate activation) has succeeded, so an early throw can never leave
          // `isStartingRecording` stuck `true`. The remainder of this closure
          // cannot throw. From here, teardown handlers and stop paths defer rather
          // than tear down the half-built engine inline (see
          // `AIOEngine.isStartingRecording`); reset the abort signal/flags.
          owner.isStartingRecording = true
          owner.startAbortRequiresFailureEvent = false
          owner.startAbortRequested = false

          return owner.recordingEngineRuntime.makeWarmInputs(
            configuration: configuration,
            alreadyActive: alreadyActive,
          )
        }

        do {
          // (c) OFF-MAIN: blocking bring-up + engine/backend start, never on main.
          try owner.recordingEngineRuntime.performWarm(
            configuration: configuration,
            inputs: inputs,
          )

          if let backend = owner.state[locked: \.activeBackend] {
            // System audio: start the Core Audio capture backend + source pump
            // instead of the AVAudioEngine.
            try backend.start()
          } else {
            let startResult = await owner.withEngineControlQueueResult { [weak owner] in
              guard let owner else { return }
              try unsafe owner.engine.start()
            }
            if case .failure(let error) = startResult {
              throw RecordingError.session(.engineStartFailed(error: ErrorContext(error)))
            }
          }
        } catch {
          // (d) Any bring-up/start failure: perform `@MainActor` cleanup, rethrow.
          await MainActor.run {
            // Close the bring-up window before tearing down so handlers stop
            // deferring; the failed engine is being torn down here regardless.
            owner.isStartingRecording = false
            owner.hardStop()
            owner.eventSubject.send(AudioIOEvent.recordingFailed)
          }
          throw error
        }

        // (e) MainActor PUBLISH hop: read staged state, validate, emit events,
        // start the writer/receiver loops, and flip `isRecording`.
        let url = try await MainActor.run { () throws(RecordingError) -> URL in
          // Close the bring-up window: from here on, teardown/stop paths act
          // inline again (the engine is being published this turn).
          owner.isStartingRecording = false

          let (buffers, writer, url, receiverBuffers, receiverTiming) = owner.state {
            (
              $0.audioBuffers, $0.recordingWriter, $0.recordingURL, $0.receiverBuffers,
              $0.receiverTiming
            )
          }
          guard let buffers,
            let processingFormat = configuration.processingFormat,
            let writeWriter = writer,
            let url
          else {
            owner.hardStop()
            owner.eventSubject.send(AudioIOEvent.recordingFailed)
            throw RecordingError.invalidConfiguration(
              details: "state after warm(configuration:) was invalid",
            )
          }
          let fileFormat = configuration.outputConfiguration.fileFormat.rawValue
          // If a teardown/stop already aborted this bring-up while we were
          // off-main, suppress `recordingStarted` — the reconcile below tears the
          // engine down, so emitting "started" then "failed" would be spurious.
          if !owner.startAbortRequested {
            owner.eventSubject.send(AudioIOEvent.recordingStarted(url: url, format: fileFormat))
          }
          owner.startFileWriteLoop(flushing: buffers, of: processingFormat, to: writeWriter)
          if let receiverBuffers, let receiverTiming {
            owner.startReceiverLoop(
              buffers: receiverBuffers,
              timing: receiverTiming,
              processingFormat: processingFormat,
            )
          }
          owner.isRecording = true
          return url
        }

        // Reconcile a stop/interruption that arrived mid-bring-up: a teardown
        // handler or stop path set `startAbortRequested = true` while we were
        // deferring (it could not tear down the half-built engine). Honour it
        // now so the freshly-started engine never stays running behind the
        // framework's back. NB: this is gated on `startAbortRequested`, not
        // `wantsRecording`, because the direct start API runs with
        // `wantsRecording == false` and must not self-abort.
        let abort: (active: Bool, emitFailure: Bool) = await MainActor.run {
          guard owner.startAbortRequested else { return (false, false) }
          owner.startAbortRequested = false
          let emitFailure = owner.startAbortRequiresFailureEvent
          owner.startAbortRequiresFailureEvent = false
          return (true, emitFailure)
        }
        if abort.active {
          await owner.gracefulStop()
          if abort.emitFailure {
            await MainActor.run {
              owner.eventSubject.send(AudioIOEvent.recordingFailed)
            }
          }
        }
        return url
      } catch let error as RecordingError {
        throw error
      } catch {
        throw .session(.engineStartFailed(error: ErrorContext(error)))
      }
    }

    @MainActor
    func updateRecordingTapInterval(_ interval: Duration) {
      guard interval > .zero else { return }

      // Tap interval is a microphone-only concept. Rebuild the configuration with
      // the new interval nested in `MicrophoneRecordingInput`; system-audio
      // configurations have no tap interval, so this is a no-op for them.
      func withUpdatedInterval(_ config: RecordingConfiguration) -> RecordingConfiguration? {
        guard case .microphone(let microphone) = config.input,
          microphone.tapInterval != interval
        else {
          return nil
        }
        return RecordingConfiguration(
          input: .microphone(
            MicrophoneRecordingInput(format: microphone.format, tapInterval: interval),
          ),
          outputConfiguration: config.outputConfiguration,
          outputDestination: config.outputDestination,
        )
      }

      guard let currentConfig = owner.state.withLock({ $0.recordingConfiguration }) else {
        // Not yet warmed: fold the interval into the pending configuration if it
        // is a microphone source, otherwise leave it untouched.
        if let pending = owner.lastRecordingConfiguration,
          let updated = withUpdatedInterval(pending)
        {
          owner.lastRecordingConfiguration = updated
        }
        return
      }

      guard let updated = withUpdatedInterval(currentConfig) else { return }

      owner.state.withLock { $0.recordingConfiguration = updated }
      owner.lastRecordingConfiguration = updated

      guard owner.isRecording else { return }

      do {
        try owner.reconfigureTapForIntervalChange(configuration: updated)
      } catch {
        log.warning(
          "Failed to update tap interval to \(interval, privacy: .public): \(error, privacy: .public)",
        )
      }
    }

    @MainActor
    func stopRecording() async throws(RecordingError) -> URL {
      // A direct stop while a bring-up is in flight cannot finalize a recording
      // (none exists yet) and must not tear the half-built engine down inline.
      // Signal the abort so the start path's PUBLISH-hop reconcile performs the
      // `gracefulStop()`, then report `.notRecording` (the contract for "stop
      // when not recording"). This is a user stop, so no `recordingFailed`.
      if owner.isStartingRecording {
        owner.wantsRecording = false
        owner.startAbortRequested = true
        throw RecordingError.notRecording
      }
      guard let url = owner.state[locked: \.recordingURL], owner.isRecording else {
        throw RecordingError.notRecording
      }
      await owner.gracefulStop()
      let fileExists = FileManager.default.fileExists(atPath: url.path)
      let fileSize = owner.fileSizeValue(for: url)
      let failure = owner.consumeWriteFailure()
      if !fileExists {
        throw RecordingError.fileFailed(
          operation: .write,
          url: url,
          error: ErrorContext(MissingAudioFileError(url: url)),
        )
      }
      if let size = fileSize, size == 0 {
        throw RecordingError.fileFailed(
          operation: .write,
          url: url,
          error: ErrorContext(EmptyAudioFileError(url: url)),
        )
      }
      if let failure {
        if owner.isWriterDrainTimeout(failure), fileExists, (fileSize ?? 0) > 0 {
          log.warning(
            "⚠️ Writer drain timed out but file exists with data; continuing stop for \(url.lastPathComponent, privacy: .public)",
          )
        } else {
          throw RecordingError.fileFailed(
            operation: .write,
            url: failure.url,
            error: failure.error,
          )
        }
      }
      let finalSize = owner.fileSizeDescription(for: url)
      log.info(
        "✅ Recording stopped: \(url.lastPathComponent, privacy: .public) size=\(finalSize, privacy: .public)",
      )
      owner.eventSubject.send(AudioIOEvent.recordingCompleted)
      return url
    }

    @MainActor
    func rotateRecordingFile() async throws(RecordingError) -> URL {
      guard owner.isRecording,
        let (currentURL, configuration, format): (URL, RecordingConfiguration, AVAudioFormat) =
          owner.state.withLock({
            guard let url = $0.recordingURL,
              let config = $0.recordingConfiguration,
              let format = config.processingFormat
            else {
              return Optional.none
            }
            return Optional((url, config, format))
          })
      else {
        throw RecordingError.notRecording
      }

      let (newURL, protection): (URL, OutputFileProtection?) = try owner.resolveOutputURL(
        for: configuration,
        allowExplicitFile: false,
      )
      let newWriter = try owner.makeRecordingWriter(
        url: newURL,
        configuration: configuration,
        writerBackend: owner.writerBackend,
      )
      owner.applyFileProtectionIfNeeded(protection, to: newURL)

      let sampleRate = Int(format.sampleRate)
      let channelCount = Int(format.channelCount)
      guard sampleRate > 0, channelCount > 0 else {
        throw RecordingError.invalidConfiguration(details: "Invalid processing format")
      }

      let newBuffers = owner.makeAudioBuffers(
        sampleRate: sampleRate,
        channelCount: channelCount,
      )

      if let currentWriter = owner.writerSession {
        owner.enqueueDrain(for: currentWriter)
      } else {
        owner.state[locked: \.recordingWriter]?.close()
      }

      let wrapped = owner.state { state -> Transferring<TapSnapshot> in
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
            convertedBuffer: state.tapConvertedBuffer,
          ),
        )
      }
      owner.recordingInfrastructure.tapSnapshotLock.withLock { $0 = wrapped.value }

      owner.startFileWriteLoop(flushing: newBuffers, of: format, to: newWriter)

      let fileFormat = configuration.outputConfiguration.fileFormat.rawValue
      owner.eventSubject.send(AudioIOEvent.recordingStarted(url: newURL, format: fileFormat))

      log.info("📼 Rotated recording file to: \(newURL.lastPathComponent, privacy: .public)")

      return currentURL
    }
  }
#endif
