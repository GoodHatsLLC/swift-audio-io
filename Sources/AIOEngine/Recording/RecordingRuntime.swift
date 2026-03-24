// © GoodHatsLLC

#if canImport(AVFoundation)
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
        owner.reconciliationTask = Task { @MainActor [weak owner] in
          guard let owner else { return }
          await RecordingRuntime(owner: owner).reconcileRecordingState(
            desiredState: true,
            configuration: configuration,
          )
        }
      } else if owner.isRecording {
        Task { @MainActor [weak owner] in
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
    func stopRecordingWithReconciliation() async -> URL? {
      owner.wantsRecording = false
      owner.reconciliationTask = nil
      guard owner.isRecording else { return nil }
      return try? await stopRecording()
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

      log.info(
        "Starting recording reconciliation (timeout: \(timeout, privacy: .public), interval: \(retryInterval, privacy: .public))",
      )

      var lastError: AIOEngine.AIOError?

      while !Task.isCancelled, owner.wantsRecording {
        let elapsed = ContinuousClock.now - startTime

        if elapsed >= timeout {
          log.warning(
            "Recording reconciliation timed out after \(elapsed, privacy: .public)",
          )
          break
        }

        do {
          try await startRecording(configuration: configuration)
          log.info("Recording started successfully after \(elapsed, privacy: .public)")
          owner.lastRecordingStartFailure = nil
          return
        } catch let error where error.isTransient {
          lastError = error
          owner.lastRecordingStartFailure = error
          log.info(
            "Transient error during reconciliation: \(error, privacy: .public), retrying...",
          )
          try? await Task.sleep(for: retryInterval)
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
        owner.onReconciliationFailed?(true)
      }
    }

    nonisolated func startRecording(
      configuration: RecordingConfiguration,
    ) async throws(AIOEngine.AIOError) {
      do {
        let shouldStopPlayer = await owner.withEngineControlQueue { [weak owner] in
          guard let owner else { return false }
          return unsafe owner.player.isPlaying
        }
        if shouldStopPlayer {
          await owner.stopPlayerIfNeeded()
        }
        try await MainActor.run {
          if shouldStopPlayer || owner.playback != nil {
            owner.playbackState[locked: \.playbackInstance] = nil
            owner.playback = nil
            owner.onPlaybackUpdated?(nil)
          }
          owner.lastWriteFailure = nil
          owner.lastRecordingConfiguration = configuration
          try owner.warm(configuration: configuration)

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
            throw AIOEngine.AIOError.invalidRecordingConfiguration(
              details: "state after warm(configuration:) was invalid",
            )
          }
          let startResult = owner.runOnEngineControlQueueResult { [weak owner] in
            guard let owner else { return }
            try unsafe owner.engine.start()
          }
          if case .failure(let error) = startResult {
            throw AIOEngine.AIOError.engineStartFailed(error: ErrorContext(error))
          }
          let fileFormat = configuration.outputConfiguration.fileFormat.rawValue
          owner.onRecordingStarted?(url, fileFormat)
          owner.startFileWriteLoop(flushing: buffers, of: processingFormat, to: writeWriter)
          if let receiverBuffers, let receiverTiming {
            owner.startReceiverLoop(
              buffers: receiverBuffers,
              timing: receiverTiming,
              processingFormat: processingFormat,
            )
          }
          owner.isRecording = true
        }
      } catch let error as AIOEngine.AIOError {
        throw error
      } catch {
        throw .engineStartFailed(error: ErrorContext(error))
      }
    }

    @MainActor
    func updateRecordingTapInterval(_ interval: Duration) {
      guard interval > .zero else { return }

      guard let currentConfig = owner.state.withLock({ $0.recordingConfiguration }) else {
        owner.lastRecordingConfiguration = owner.lastRecordingConfiguration.map {
          RecordingConfiguration(
            inputConfiguration: $0.inputConfiguration,
            outputConfiguration: $0.outputConfiguration,
            tapInterval: interval,
            outputDestination: $0.outputDestination,
          )
        }
        return
      }

      let updated = RecordingConfiguration(
        inputConfiguration: currentConfig.inputConfiguration,
        outputConfiguration: currentConfig.outputConfiguration,
        tapInterval: interval,
        outputDestination: currentConfig.outputDestination,
      )

      guard updated.tapInterval != currentConfig.tapInterval else { return }

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
    func stopRecording() async throws(AIOEngine.AIOError) -> URL {
      guard let url = owner.state[locked: \.recordingURL], owner.isRecording else {
        throw AIOEngine.AIOError.notRecording
      }
      await owner.gracefulStop()
      let fileExists = FileManager.default.fileExists(atPath: url.path)
      let fileSize = owner.fileSizeValue(for: url)
      let failure = owner.consumeWriteFailure()
      if !fileExists {
        throw AIOEngine.AIOError.audioFileFailed(
          operation: .write,
          url: url,
          error: ErrorContext(MissingAudioFileError(url: url)),
        )
      }
      if let size = fileSize, size == 0 {
        throw AIOEngine.AIOError.audioFileFailed(
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
          throw AIOEngine.AIOError.audioFileFailed(
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
      owner.onRecordingCompleted?()
      return url
    }

    @MainActor
    func rotateRecordingFile() async throws(AIOEngine.AIOError) -> URL {
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
        throw AIOEngine.AIOError.notRecording
      }

      let (newURL, protection): (URL, OutputFileProtection?) = try owner.resolveOutputURL(
        for: configuration,
        allowExplicitFile: false,
      )
      let newWriter = try owner.makeRecordingWriter(url: newURL, configuration: configuration)
      owner.applyFileProtectionIfNeeded(protection, to: newURL)

      let sampleRate = Int(format.sampleRate)
      let channelCount = Int(format.channelCount)
      guard sampleRate > 0, channelCount > 0 else {
        throw AIOEngine.AIOError.invalidRecordingConfiguration(details: "Invalid processing format")
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
      owner.tapSnapshotLock.withLock { $0 = wrapped.value }

      owner.startFileWriteLoop(flushing: newBuffers, of: format, to: newWriter)

      let fileFormat = configuration.outputConfiguration.fileFormat.rawValue
      owner.onRecordingStarted?(newURL, fileFormat)

      log.info("📼 Rotated recording file to: \(newURL.lastPathComponent, privacy: .public)")

      return currentURL
    }
  }
#endif
