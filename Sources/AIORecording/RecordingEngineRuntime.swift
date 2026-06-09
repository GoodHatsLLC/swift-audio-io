// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOContracts
  import AIOSupport
  import AIOEngineCore
  import AIORecordingSupport
  import Atomics
  import AVFoundation
  import Foundation
  import os
  import Tools

  private let log = SystemLog.make()

  private enum RecordingRuntimeBlockingDelay {
    static func sleep(for seconds: TimeInterval) {
      Thread.sleep(forTimeInterval: seconds)
    }
  }

  extension AIOEngine {
    var recordingEngineRuntime: RecordingEngineRuntime {
      RecordingEngineRuntime(owner: self)
    }
  }

  struct RecordingEngineRuntime {
    static let currentMaximumRecordingChannelCount = 32

    let owner: AIOEngine

    @MainActor
    func startFileWriteLoop(
      flushing buffers: [SPSCRingBuffer<Float>],
      of processingFormat: AVAudioFormat,
      to writer: any RecordingFileWriter,
    ) {
      let control = WriterControl()
      let localMetrics = owner.metrics
      let (tapErrorPoll, onTapError) = owner.makeTapErrorHandlers()
      let callbackTasks = owner.recordingCallbackTasks
      let errorHandler: @Sendable (ErrorContext) -> Void = { [weak owner, callbackTasks] error in
        guard let owner else { return }
        callbackTasks.run { [weak owner] in
          await MainActor.run {
            guard let owner else { return }
            owner.recordingEngineRuntime.recordWriteFailure(error, url: writer.fileURL)
            owner.eventSubject.send(
              .error(
                RecordingError.fileFailed(
                  operation: .write,
                  url: writer.fileURL,
                  error: error,
                ),
              ),
            )
            owner.eventSubject.send(AudioIOEvent.recordingFailed)
          }
        }
      }
      let session = WriterSession(
        id: UUID(),
        control: control,
        writer: writer,
        fileURL: writer.fileURL,
      )
      owner.writerSession = session
      let writeBufferSize = 1024
      let preAllocatedBuffer = Transferring(
        AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: AVAudioFrameCount(writeBufferSize),
        ),
      )
      owner.writerQueue.async { [control, localMetrics] in
        RecordingEngineRuntime.writerLoopSync(
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
          onTapError: onTapError,
        )
      }
      log.info("📝 Writer started for \(writer.fileURL.lastPathComponent, privacy: .public)")
    }

    @MainActor
    func startReceiverLoop(
      buffers: [SPSCRingBuffer<Float>],
      timing: SPSCRingBuffer<TimingPacket>,
      processingFormat: AVAudioFormat,
    ) {
      stopReceiverLoop()
      let control = ReceiverControl()
      let session = ReceiverSession(
        id: UUID(),
        control: control,
        buffers: buffers,
        timing: timing,
        processingFormat: processingFormat,
      )
      owner.receiverSession = session
      #if DEBUG
        let onUnderrun: @Sendable () -> Void = { [metrics = owner.metrics] in
          metrics.receiverUnderruns.wrappingIncrement(ordering: .relaxed)
        }
        let onDrop: @Sendable () -> Void = { [metrics = owner.metrics] in
          metrics.receiverDrops.wrappingIncrement(ordering: .relaxed)
        }
      #else
        let onUnderrun: (@Sendable () -> Void)? = nil
        let onDrop: (@Sendable () -> Void)? = nil
      #endif
      let (tapErrorPoll, onTapError) = owner.makeTapErrorHandlers()
      let cadence = owner.receiverPollingInterval
      owner.receiverQueue.async {
        let bufferReceivers = owner.bufferReceivers
        RecordingEngineRuntime.receiverLoopSync(
          buffers: buffers,
          timing: timing,
          processingFormat: processingFormat,
          bufferReceivers: bufferReceivers,
          control: control,
          cadence: cadence,
          onUnderrun: onUnderrun,
          onDrop: onDrop,
          tapErrorPoll: tapErrorPoll,
          onTapError: onTapError,
        )
      }
    }

    @MainActor
    func stopReceiverLoop() {
      guard let session = owner.receiverSession else { return }
      session.control.cancelRequested.store(true, ordering: .relaxed)
      owner.receiverSession = nil
    }

    @MainActor
    func prepareDrain(for session: WriterSession, targetSampleTime: Int64, logBuffers: Bool) {
      session.control.stopRequested.store(true, ordering: .relaxed)
      session.control.targetSampleTime.store(targetSampleTime, ordering: .relaxed)
      let written = session.control.writtenSampleTime.load(ordering: .relaxed)
      if written >= targetSampleTime {
        session.control.targetSatisfiedSignal.signalFromSynchronousContext()
      }
      if logBuffers {
        let counts = owner.state.withLock { $0.audioBuffers?.map(\.availableToRead) ?? [] }
        log.info(
          "🧹 Stop target set: target=\(targetSampleTime, privacy: .public) written=\(written, privacy: .public) buffers=\(counts, privacy: .public)",
        )
      } else {
        log.info(
          "🧹 Stop target set: target=\(targetSampleTime, privacy: .public) (non-current session)",
        )
      }
    }

    @MainActor
    func drainWriterSession(_ session: WriterSession, notifyOnFailure: Bool) async {
      let start = owner.clock.now
      log.info("🧹 Drain start for \(session.fileURL.lastPathComponent, privacy: .public)")
      let outcome = await owner.awaitWriterDrainOutcome(session)
      let elapsed = start.duration(to: owner.clock.now)
      switch outcome {
      case .signaled:
        session.writer.close()
        let size = owner.fileSizeDescription(for: session.fileURL)
        log.info(
          "🧹 Writer drained for \(session.fileURL.lastPathComponent, privacy: .public) (size=\(size, privacy: .public), elapsed=\(elapsed, privacy: .public))",
        )
      case .targetSatisfied:
        session.control.cancelRequested.store(true, ordering: .relaxed)
        session.writer.close()
        let target = session.control.targetSampleTime.load(ordering: .relaxed)
        let written = session.control.writtenSampleTime.load(ordering: .relaxed)
        log.info(
          "🧹 Drain short-circuit: target satisfied for \(session.fileURL.lastPathComponent, privacy: .public) target=\(target, privacy: .public) written=\(written, privacy: .public) elapsed=\(elapsed, privacy: .public)",
        )
      case .timedOut:
        let error = WriterDrainTimeoutError(url: session.fileURL, timeout: owner.writerDrainTimeout)
        session.control.cancelRequested.store(true, ordering: .relaxed)
        session.writer.close()
        let target = session.control.targetSampleTime.load(ordering: .relaxed)
        let written = session.control.writtenSampleTime.load(ordering: .relaxed)
        log.error(
          "⏱️ Writer drain timed out for \(session.fileURL.lastPathComponent, privacy: .public) after \(elapsed, privacy: .public): \(error, privacy: .public) target=\(target, privacy: .public) written=\(written, privacy: .public)",
        )
        recordWriteFailure(ErrorContext(error), url: session.fileURL)
        if notifyOnFailure {
          owner.eventSubject.send(
            .error(
              RecordingError.fileFailed(
                operation: .write,
                url: session.fileURL,
                error: ErrorContext(error),
              ),
            ),
          )
          owner.eventSubject.send(AudioIOEvent.recordingFailed)
        }
      }
    }

    @MainActor
    func enqueueDrain(for session: WriterSession) {
      let target = owner.recordingSampleTimeAtomic.load(ordering: .relaxed)
      prepareDrain(
        for: session,
        targetSampleTime: target,
        logBuffers: session.id == owner.writerSession?.id,
      )
      owner.drainingWriterSessions.append(session)
      owner.recordingCallbackTasks.run { [weak owner] in
        guard let owner else { return }
        await owner.recordingEngineRuntime.drainWriterSession(session, notifyOnFailure: true)
        await MainActor.run { owner.drainingWriterSessions.removeAll { $0.id == session.id } }
      }
    }

    @MainActor
    func stopAndDrainAllWriterSessions(notifyOnFailure: Bool) async {
      if Task.isCancelled {
        log.warning("🧹 stopAndDrainAllWriterSessions cancelled before start")
        return
      }
      var sessions: [WriterSession] = []
      if let current = owner.writerSession {
        sessions.append(current)
      }
      sessions.append(contentsOf: owner.drainingWriterSessions)

      let target = owner.recordingSampleTimeAtomic.load(ordering: .relaxed)
      for session in sessions {
        if Task.isCancelled {
          log.warning("🧹 stopAndDrainAllWriterSessions cancelled before stop request")
          return
        }
        log.info(
          "🧹 Stop requested for writer \(session.fileURL.lastPathComponent, privacy: .public)",
        )
        prepareDrain(
          for: session,
          targetSampleTime: target,
          logBuffers: session.id == owner.writerSession?.id,
        )
      }
      for session in sessions {
        if Task.isCancelled {
          log.warning("🧹 stopAndDrainAllWriterSessions cancelled before drain wait")
          return
        }
        log.info("🧹 Drain wait start for \(session.fileURL.lastPathComponent, privacy: .public)")
        await drainWriterSession(session, notifyOnFailure: notifyOnFailure)
      }

      owner.writerSession = nil
      owner.drainingWriterSessions.removeAll()
      log.info("🧹 stopAndDrainAllWriterSessions completed")
    }

    @MainActor
    func cancelAllWriterSessions() {
      if let current = owner.writerSession {
        current.control.cancelRequested.store(true, ordering: .relaxed)
      }
      for session in owner.drainingWriterSessions {
        session.control.cancelRequested.store(true, ordering: .relaxed)
      }
      owner.writerSession = nil
      owner.drainingWriterSessions.removeAll()
      log.info("🧹 cancelAllWriterSessions completed")
    }

    @MainActor
    func recordWriteFailure(_ error: ErrorContext, url: URL?) {
      guard owner.lastWriteFailure == nil else { return }
      owner.lastWriteFailure = WriteFailure(url: url, error: error)
      log.error(
        "🛑 Recording write failed for \(url?.lastPathComponent ?? "missing URL", privacy: .public): \(error, privacy: .public)",
      )
    }

    @MainActor
    func consumeWriteFailure() -> WriteFailure? {
      defer { owner.lastWriteFailure = nil }
      return owner.lastWriteFailure
    }

    @MainActor
    func warm(configuration: RecordingConfiguration) throws(RecordingError) {
      guard !owner.isRecording, !owner.isPlaying else {
        return
      }
      try validateRecordingChannelCapacity(for: configuration)
      try validateEncoderCompatibility(for: configuration)

      guard let processingFormat = configuration.processingFormat else {
        throw RecordingError.invalidConfiguration(details: "(processing format)")
      }

      let sampleRate = Int(processingFormat.sampleRate)
      let channelCount = Int(processingFormat.channelCount)
      guard sampleRate > 0, channelCount > 0 else {
        throw RecordingError.session(
          .notReady(details: "Invalid format: \(sampleRate)Hz, \(channelCount)ch"),
        )
      }
      guard sampleRate < Int.max / channelCount / 2 else {
        throw RecordingError.hardwareNotSupported
      }
      try validateRecordingChannelCapacity(channelCount: channelCount)

      if let existing = owner.state[locked: \.recordingConfiguration] {
        if configuration == existing {
          log.info("engine already warmed")
          owner.recordingSampleTimeAtomic.store(0, ordering: .relaxed)
          owner.recordingFirstHostTimeAtomic.store(0, ordering: .relaxed)
          owner.recordingFirstSourceSampleTimeAtomic.store(Int64.min, ordering: .relaxed)
          return
        } else {
          hardStop()
        }
      }

      owner.runOnEngineControlQueue { [weak owner] in
        guard let owner else { return }
        unsafe owner.player.stop()
        unsafe owner.engine.stop()
        unsafe owner.engine.reset()
        if unsafe !owner.engine.attachedNodes.contains(owner.player) {
          unsafe owner.engine.attach(owner.player)
        }
      }

      do throws(RecordingError) {
        log.info("warming with config: \(configuration, privacy: .public)")
        do {
          try owner.configureAudioSession(for: configuration)
        } catch let sessionError {
          throw RecordingError.session(sessionError)
        }

        owner.recordingSampleTimeAtomic.store(0, ordering: .relaxed)
        owner.recordingFirstHostTimeAtomic.store(0, ordering: .relaxed)
        owner.recordingFirstSourceSampleTimeAtomic.store(Int64.min, ordering: .relaxed)

        let tapResult = try owner.reinstallTap(
          configuration: configuration,
          processingFormat: processingFormat,
          stopEngine: false,
        )

        let audioBuffers = makeAudioBuffers(sampleRate: sampleRate, channelCount: channelCount)
        let receiverBuffers = makeAudioBuffers(sampleRate: sampleRate, channelCount: channelCount)
        let timingCapacity = max(
          64,
          Int(ceil(Double(sampleRate) / Double(tapResult.tapConfiguration.bufferSize))) * 4,
        )
        let receiverTiming = SPSCRingBuffer<TimingPacket>(capacity: timingCapacity)

        let (url, protection): (URL, OutputFileProtection?) = try owner.resolveOutputURL(
          for: configuration,
          allowExplicitFile: true,
        )
        let writer = try owner.makeRecordingWriter(url: url, configuration: configuration)
        owner.applyFileProtectionIfNeeded(protection, to: url)

        owner.state {
          $0.recordingWriter = writer
          $0.recordingURL = url
          $0.audioBuffers = audioBuffers
          $0.receiverBuffers = receiverBuffers
          $0.receiverTiming = receiverTiming
          $0.recordingConfiguration = configuration
        }
        owner.applyTapInstallResult(tapResult, processingFormat: processingFormat)
      } catch {
        log.error("Failed to warm engine: \(error, privacy: .public)")
        hardStop()
        owner.eventSubject.send(AudioIOEvent.recordingFailed)
        throw error
      }
    }

    func makeAudioBuffers(
      sampleRate: Int,
      channelCount: Int,
    ) -> [SPSCRingBuffer<Float>] {
      precondition(
        channelCount <= Self.currentMaximumRecordingChannelCount,
        "Recording channel count \(channelCount) exceeds current runtime capacity \(Self.currentMaximumRecordingChannelCount). Validate before allocating buffers.",
      )
      let capacity = max(1, Int(Double(sampleRate) * owner.maxBufferSeconds))
      return (0..<channelCount).map { _ in
        SPSCRingBuffer<Float>(capacity: capacity)
      }
    }

    func validateRecordingChannelCapacity(
      channelCount: Int,
    ) throws(RecordingError) {
      try validateRecordingChannelCapacity(
        channelCount: channelCount,
        maximum: Self.currentMaximumRecordingChannelCount,
      )
    }

    func validateRecordingChannelCapacity(
      for configuration: RecordingConfiguration,
    ) throws(RecordingError) {
      try validateRecordingChannelCapacity(
        channelCount: configuration.format.channels.count,
        maximum: min(
          Self.currentMaximumRecordingChannelCount,
          configuration.outputConfiguration.fileFormat.maximumRecordingChannelCount,
        ),
      )
    }

    private func validateRecordingChannelCapacity(
      channelCount: Int,
      maximum: Int,
    ) throws(RecordingError) {
      guard channelCount > 0 else {
        throw RecordingError.invalidConfiguration(
          details: "Channel count must be at least 1.",
        )
      }
      guard channelCount <= maximum else {
        throw RecordingError.unsupportedChannelCount(
          requested: channelCount,
          maximum: maximum,
        )
      }
    }

    @MainActor
    func validateEncoderCompatibility(
      for configuration: RecordingConfiguration,
    ) throws(RecordingError) {
      let fileFormat = configuration.outputConfiguration.fileFormat
      guard fileFormat == .aac || fileFormat == .adts else { return }

      let sampleRate = configuration.format.sampleRate.hz
      guard fileFormat.supportsEncodedSampleRate(sampleRate) else {
        throw RecordingError.unsupportedEncodedSampleRate(
          fileFormat: fileFormat,
          sampleRate: sampleRate,
          supportedSampleRates: FileFormat.aacCompatibleSampleRates,
        )
      }
    }

    @MainActor
    func reconfigureTapForIntervalChange(
      configuration: RecordingConfiguration,
    ) throws(RecordingError) {
      guard let processingFormat = owner.state.withLock({ $0.tapConverterOutputFormat }) else {
        return
      }

      let result = try owner.reinstallTap(
        configuration: configuration,
        processingFormat: processingFormat,
        stopEngine: false,
      )
      owner.applyTapInstallResult(result, processingFormat: processingFormat)

      log.info(
        "Updated tap interval to \(configuration.tapInterval, privacy: .public) (bufferSize: \(result.tapConfiguration.bufferSize, privacy: .public) frames)",
      )
    }

    @MainActor
    func hardStop() {
      if owner.state[locked: \.activeBackend] == nil {
        let tapBus = owner.state.consume(\.installedTapBus)
        let busesToRemove = Array(Set([tapBus, 0].compactMap(\.self)))
        owner.runOnEngineControlQueue { [weak owner] in
          guard let owner else { return }
          dispatchPrecondition(condition: .onQueue(owner.engineControlQueue))
          for bus in busesToRemove {
            unsafe owner.engine.inputNode.removeTap(onBus: bus)
          }
          if unsafe owner.engine.isRunning {
            unsafe owner.engine.stop()
          }
          if unsafe owner.player.isPlaying {
            unsafe owner.player.stop()
          }
          unsafe owner.engine.reset()
        }
      } else {
        // System-audio capture is torn down by cleanUp() -> backend.cleanup();
        // there is no AVAudioEngine input tap to remove.
        _ = owner.state.consume(\.installedTapBus)
      }
      let hasActiveWriter = owner.writerSession != nil || !owner.drainingWriterSessions.isEmpty
      if let current = owner.writerSession {
        enqueueDrain(for: current)
        owner.writerSession = nil
      }
      cleanUp(closeFile: !hasActiveWriter)
    }

    @MainActor
    func gracefulStop() async {
      log.info("gracefulStop requested")
      if let backend = owner.state[locked: \.activeBackend] {
        log.info("gracefulStop stopping capture backend")
        do {
          try backend.stop()
        } catch {
          log.error(
            "capture backend stop failed during gracefulStop: \(error, privacy: .public)",
          )
        }
      } else {
        let tapBus = owner.state.consume(\.installedTapBus)
        let busesToRemove = Array(Set([tapBus, 0].compactMap(\.self)))
        log.info("gracefulStop starting (tapBus=\(String(describing: tapBus), privacy: .public))")
        owner.engineControlQueue.async { [weak owner] in
          guard let owner else { return }
          dispatchPrecondition(condition: .onQueue(owner.engineControlQueue))
          for bus in busesToRemove {
            unsafe owner.engine.inputNode.removeTap(onBus: bus)
          }
          unsafe owner.engine.stop()
        }
      }
      log.info("gracefulStop draining writer sessions")
      let stopDrainTimeout = owner.stopDrainTimeout
      let stopDrainTimeoutPolicy = TimeoutPolicy(stopDrainTimeout)
      let drainCompleted = await withTaskGroup(of: Bool.self) { group in
        group.addTask { [self] in
          await stopAndDrainAllWriterSessions(notifyOnFailure: false)
          return true
        }
        group.addTask {
          try? await stopDrainTimeoutPolicy.waitForTimeout()
          return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
      }
      if !drainCompleted {
        let url = owner.state[locked: \.recordingURL]
        let error = WriterDrainTimeoutError(url: url, timeout: stopDrainTimeout)
        log.error("stopAndDrainAllWriterSessions timed out: \(error, privacy: .public)")
        cancelAllWriterSessions()
        recordWriteFailure(ErrorContext(error), url: url)
      }
      cleanUp()
      owner.isRecording = false
      owner.wantsRecording = false
      owner.reconciliationTask = nil
      log.info("gracefulStop completed")
      owner.deactivateAudioSessionIfNeeded(reason: "recording stopped")
    }

    @MainActor
    func cleanUp(closeFile: Bool = true) {
      stopReceiverLoop()
      owner.tapErrorCode.store(0, ordering: .relaxed)
      let (writer, backend) = owner.state {
        state -> ((any RecordingFileWriter)?, (any RecordingCaptureBackend)?) in
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
          state.activeBackend = nil
        }
        return (state.recordingWriter, state.activeBackend)
      }
      // Single, idempotent teardown point for the capture backend (system audio).
      // The microphone path has no backend; this is a no-op there.
      backend?.cleanup()
      owner.recordingInfrastructure.tapSnapshotLock.withLock { $0 = .empty }
      if closeFile {
        writer?.close()
      }
      owner.playbackTask = nil
    }

    nonisolated
      func processAudio(
        buffer: AVAudioPCMBuffer,
        time: AVAudioTime?,
        to processingFormat: AVAudioFormat,
      )
    {
      #if DEBUG
        let tapStart = DispatchTime.now().uptimeNanoseconds
      #endif
      let frameLength = buffer.frameLength
      guard frameLength > 0 else { return }

      let snapshot: TapSnapshot
      if let locked = owner.state.withLockIfAvailable({ state in
        Transferring(
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
      }) {
        snapshot = locked.value
        owner.recordingInfrastructure.tapSnapshotLock.withLockIfAvailable { $0 = locked.value }
      } else {
        if let cached = owner.recordingInfrastructure.tapSnapshotLock.withLockIfAvailable({
          Transferring($0)
        }) {
          snapshot = cached.value
        } else {
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
        owner.recordTapError(.converterMissing)
        return
      }

      let frameRatio = processingFormat.sampleRate / buffer.format.sampleRate
      let requestedCapacity = max(
        AVAudioFrameCount(ceil(Double(frameLength) * frameRatio)),
        1,
      )
      guard let convertedBuffer else {
        owner.recordTapError(.converterMissing)
        return
      }
      guard convertedBuffer.frameCapacity >= requestedCapacity else {
        owner.requestTapResize(frames: Int(requestedCapacity))
        owner.recordTapError(.bufferTooSmall)
        return
      }
      convertedBuffer.frameLength = requestedCapacity

      var error: NSError? = nil
      let inputBuffer = Transferring(buffer)
      let status = unsafe converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
        unsafe outStatus.pointee = .haveData
        return inputBuffer.value
      }
      guard status != .error else {
        owner.recordTapError(.conversionFailed)
        return
      }
      guard let audioBuffers else {
        return
      }

      let channelCount = Int(convertedBuffer.format.channelCount)
      let effectiveChannelCount = min(channelCount, audioBuffers.count)
      guard effectiveChannelCount > 0 else { return }
      if channelCount > audioBuffers.count, rtLoggingEnabled {
        log.error(
          "Channel count mismatch: \(channelCount, privacy: .public) vs \(audioBuffers.count, privacy: .public)",
        )
      }
      let convertedFrameLength = Int(convertedBuffer.frameLength)
      let writerAvailable = RecordingEngineRuntime.minimumAvailableWriteFrames(
        channelCount: effectiveChannelCount,
        audioBuffers: audioBuffers,
        limit: convertedFrameLength,
      )
      let writerCanWrite = writerAvailable >= convertedFrameLength
      let receiverCanWrite: Bool
      if let receiverBuffers, let timingBuffer {
        let timingHasCapacity = timingBuffer.availableToWrite >= 1
        receiverCanWrite =
          timingHasCapacity
          && RecordingEngineRuntime.minimumAvailableWriteFrames(
            channelCount: effectiveChannelCount,
            audioBuffers: receiverBuffers,
            limit: convertedFrameLength,
          ) >= convertedFrameLength
      } else {
        receiverCanWrite = false
      }
      #if DEBUG
        if !writerCanWrite {
          owner.metrics.writerDrops.wrappingIncrement(
            by: Int64(convertedFrameLength),
            ordering: .relaxed,
          )
        }
        if receiverBuffers != nil, !receiverCanWrite {
          owner.metrics.receiverDrops.wrappingIncrement(
            by: Int64(convertedFrameLength),
            ordering: .relaxed,
          )
        }
      #endif

      let processingStartSampleTime = owner.recordingSampleTimeAtomic.load(ordering: .relaxed)
      let sourceHostTime: UInt64? =
        (time?.isHostTimeValid ?? false) ? time?.hostTime : nil
      let sourceSampleTime: Int64? =
        (time?.isSampleTimeValid ?? false) ? time.map { Int64($0.sampleTime) } : nil
      let sourceSampleRate: Double? =
        (time?.isSampleTimeValid ?? false) ? time?.sampleRate : nil
      // Anchor the first captured frame that carries a valid host time so a post-stop reader can
      // align this recording against other devices (see `RecordingTimingSnapshot`). There is a
      // single real-time tap writer, so a load-then-store gated on the unset sentinel (0) is
      // wait-free and race-free. The source sample time is stored before the host time so a reader
      // observing a non-zero host time also observes the paired sample time.
      if let sourceHostTime, owner.recordingFirstHostTimeAtomic.load(ordering: .relaxed) == 0 {
        owner.recordingFirstSourceSampleTimeAtomic.store(
          sourceSampleTime ?? Int64.min,
          ordering: .relaxed,
        )
        owner.recordingFirstHostTimeAtomic.store(sourceHostTime, ordering: .relaxed)
      }
      if writerCanWrite || receiverCanWrite {
        for i in 0..<effectiveChannelCount {
          guard let channelData = unsafe convertedBuffer.floatChannelData?[i] else {
            if rtLoggingEnabled {
              log.error("Failed to access channel data for channel \(i, privacy: .public)")
            }
            continue
          }
          if writerCanWrite {
            unsafe audioBuffers[i].write(
              UnsafeBufferPointer(start: channelData, count: convertedFrameLength),
            )
          }
          if receiverCanWrite, let receiverBuffers, i < receiverBuffers.count {
            unsafe receiverBuffers[i].write(
              UnsafeBufferPointer(start: channelData, count: convertedFrameLength),
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
          sourceSampleRate: sourceSampleRate,
        )
        _ = unsafe withUnsafePointer(to: &packet) { pointer in
          unsafe receiverTimingBuffer.write(UnsafeBufferPointer(start: pointer, count: 1))
        }
      }

      owner.recordingSampleTimeAtomic.wrappingIncrement(
        by: Int64(convertedBuffer.frameLength),
        ordering: .relaxed,
      )
      #if DEBUG
        owner.metrics.tapCallbackCount.wrappingIncrement(ordering: .relaxed)
        let tapElapsed = DispatchTime.now().uptimeNanoseconds &- tapStart
        let previousMax = owner.metrics.tapCallbackMaxNanos.load(ordering: .relaxed)
        if tapElapsed > previousMax {
          owner.metrics.tapCallbackMaxNanos.store(tapElapsed, ordering: .relaxed)
        }
      #endif
    }

    nonisolated
      func formatsCompatible(
        _ lhs: AVAudioFormat,
        _ rhs: AVAudioFormat,
      ) -> Bool
    {
      lhs.commonFormat == rhs.commonFormat
        && lhs.sampleRate == rhs.sampleRate
        && lhs.channelCount == rhs.channelCount
        && lhs.isInterleaved == rhs.isInterleaved
    }

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
      onTapError: (@Sendable (TapErrorCode) -> Void)?,
    ) {
      #if !DEBUG
        _ = metrics
      #endif
      let bufferSize = 1024
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
          using: writeBuffer,
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
              control.targetSatisfiedSignal.signalFromSynchronousContext()
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
                "🧹 Writer stop requested: target=\(control.targetSampleTime.load(ordering: .relaxed), privacy: .public) written=\(writtenSampleTime, privacy: .public) file=\(writer.fileURL.lastPathComponent, privacy: .public)",
              )
            }
            if stopRequested,
              minimumAvailableFrames(
                channelCount: Int(format.channelCount),
                audioBuffers: audioBuffers,
                limit: bufferSize,
              ) == 0
            {
              break
            }
            if stopRequested {
              let target = control.targetSampleTime.load(ordering: .relaxed)
              if writtenSampleTime >= target {
                control.targetSatisfiedSignal.signalFromSynchronousContext()
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
                let counts = audioBuffers.map(\.availableToRead)
                let minAvail = minimumAvailableFrames(
                  channelCount: Int(format.channelCount),
                  audioBuffers: audioBuffers,
                  limit: bufferSize,
                )
                log.warning(
                  "🧹 Writer stall after stop: elapsed=\(elapsed, privacy: .public) minAvail=\(minAvail, privacy: .public) counts=\(counts, privacy: .public)",
                )
              }
            }
            if shouldCancel() { break }
            let sleepMillis = stopRequested ? 1.0 : idleBackoffMillis
            RecordingRuntimeBlockingDelay.sleep(for: sleepMillis / 1000.0)
            if !stopRequested {
              idleBackoffMillis = min(idleBackoffMillis * 2, 8)
            }
          }
        case .failure(let error):
          errorHandler(ErrorContext(error))
        }
      }
      log.info("🧹 writerLoop exiting for \(writer.fileURL.lastPathComponent, privacy: .public)")
      control.drainSignal.signalFromSynchronousContext()
    }

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
      onTapError: (@Sendable (TapErrorCode) -> Void)?,
    ) {
      let channelCount = min(Int(processingFormat.channelCount), buffers.count)
      guard channelCount > 0 else { return }

      let timingScratch = UnsafeMutableBufferPointer<TimingPacket>.allocate(capacity: 1)
      defer { unsafe timingScratch.deallocate() }

      var scratchCapacity = 0
      var scratchBuffers: [UnsafeMutableBufferPointer<Float>] = unsafe []
      func ensureScratchCapacity(_ needed: Int) {
        guard needed > scratchCapacity else { return }
        unsafe scratchBuffers.forEach {
          unsafe $0.baseAddress?.deallocate()
        }
        unsafe scratchBuffers = unsafe (0..<channelCount).map { _ in
          let pointer = UnsafeMutablePointer<Float>.allocate(capacity: needed)
          return unsafe UnsafeMutableBufferPointer(start: pointer, count: needed)
        }
        scratchCapacity = needed
      }
      defer {
        unsafe scratchBuffers.forEach {
          unsafe $0.baseAddress?.deallocate()
        }
      }

      let sleepInterval = max(
        0.001,
        cadence / Duration.seconds(1.0),
      )

      let maxBacklog = 4
      while !control.cancelRequested.load(ordering: .relaxed) {
        if let tapErrorPoll, let onTapError, let code = tapErrorPoll() {
          onTapError(code)
        }
        var backlog = timing.availableToRead
        while backlog > maxBacklog, !control.cancelRequested.load(ordering: .relaxed) {
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
              count: droppedPacket.frameCount,
            )
            _ = unsafe buffers[index].read(into: destination)
          }
          onDrop?()
          backlog = timing.availableToRead
        }
        let timingRead = unsafe timing.read(into: timingScratch)
        guard timingRead > 0 else {
          RecordingRuntimeBlockingDelay.sleep(for: sleepInterval)
          continue
        }
        let packet = unsafe timingScratch[0]
        guard packet.frameCount > 0 else { continue }

        ensureScratchCapacity(packet.frameCount)
        var actualFrames = packet.frameCount
        for index in 0..<channelCount {
          let destination = unsafe UnsafeMutableBufferPointer(
            start: scratchBuffers[index].baseAddress,
            count: packet.frameCount,
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
          sourceSampleRate: packet.sourceSampleRate,
        )
        let bufferPointer = unsafe UnsafeBufferPointer(start: base, count: actualFrames)
        for bufferReceiver in bufferReceivers({ $0 }) {
          unsafe bufferReceiver.processBuffer(bufferPointer, timing: timing)
        }
      }
    }

    static func flushChunk(
      size bufferSize: Int,
      from audioBuffers: [SPSCRingBuffer<Float>],
      in audioFormat: AVAudioFormat,
      to writer: any RecordingFileWriter,
      using reusableBuffer: AVAudioPCMBuffer? = nil,
      clock: ContinuousClock = .continuous,
    ) -> Result<WriteResult, any Error> {
      let channelCount = Int(audioFormat.channelCount)
      precondition(
        channelCount <= audioBuffers.count,
        "flushChunk invariant violated: format has \(channelCount) channels but only \(audioBuffers.count) channel buffers are available.",
      )
      let framesToRead = minimumAvailableFrames(
        channelCount: channelCount,
        audioBuffers: audioBuffers,
        limit: bufferSize,
      )

      guard framesToRead > 0 else {
        return .success(.init(framesRead: 0, writeDuration: nil))
      }

      let pcmBuffer: AVAudioPCMBuffer
      if let reusableBuffer, reusableBuffer.frameCapacity >= AVAudioFrameCount(bufferSize) {
        pcmBuffer = reusableBuffer
      } else {
        guard
          let freshBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(bufferSize),
          )
        else {
          return .success(.init(framesRead: 0, writeDuration: nil))
        }
        pcmBuffer = freshBuffer
      }

      var actualFrames = framesToRead
      for i in 0..<channelCount {
        guard let channelData = unsafe pcmBuffer.floatChannelData?[i] else {
          return .success(.init(framesRead: 0, writeDuration: nil))
        }
        let readSize = unsafe audioBuffers[i].read(
          into: UnsafeMutableBufferPointer(start: channelData, count: framesToRead),
        )
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
            "🐢 Slow write: \(elapsed, privacy: .public) frames=\(actualFrames, privacy: .public) file=\(writer.fileURL.lastPathComponent, privacy: .public)",
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
      limit: Int,
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
      limit: Int,
    ) -> Int {
      guard channelCount > 0 else { return 0 }

      var minimum = limit
      for index in 0..<min(channelCount, audioBuffers.count) {
        minimum = min(minimum, audioBuffers[index].availableToWrite)
        if minimum == 0 { break }
      }
      return minimum
    }

    nonisolated
      func isWriterDrainTimeout(_ failure: WriteFailure) -> Bool
    {
      failure.error.domain.contains("WriterDrainTimeoutError")
        || failure.error.message.localizedCaseInsensitiveContains("writer drain timed out")
    }
  }
#endif
