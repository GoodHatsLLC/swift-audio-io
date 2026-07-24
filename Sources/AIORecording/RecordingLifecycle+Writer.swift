// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOEngineCore
  package import AIORecordingSupport
  import AIOSupport
  import Atomics
  package import AVFoundation
  import Foundation
  import os
  import Tools

  private let log = SystemLog.make()

  extension RecordingLifecycle {
    package var writer: Writer {
      Writer(owner: owner)
    }

    package struct Writer {
      let owner: AIOEngine

      @MainActor
      package func start(
        flushing buffers: [SPSCRingBuffer<Float>],
        format: AVAudioFormat,
        to fileWriter: any RecordingFileWriter,
      ) {
        let control = WriterControl()
        let localMetrics = owner.metrics
        let (tapErrorPoll, onTapError) = owner.makeTapErrorHandlers()
        let callbackTasks = owner.recordingCallbackTasks
        let errorHandler: @Sendable (ErrorContext) -> Void = {
          [weak owner, callbackTasks] error in
          guard let owner else { return }
          callbackTasks.run { [weak owner] in
            await MainActor.run {
              guard let owner else { return }
              RecordingLifecycle(owner: owner).writer.recordFailure(
                error,
                url: fileWriter.fileURL,
              )
              owner.eventSubject.send(
                .error(
                  RecordingError.fileFailed(
                    operation: .write,
                    url: fileWriter.fileURL,
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
          writer: fileWriter,
          fileURL: fileWriter.fileURL,
        )
        owner.recordingLifecycleState.writerSession = session
        let writeBufferSize = 1024
        let preAllocatedBuffer = Transferring(
          AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(writeBufferSize),
          ),
        )
        owner.writerQueue.async { [control, localMetrics] in
          Writer.runLoop(
            writer: fileWriter,
            format: format,
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
        log.info("📝 Writer started for \(fileWriter.fileURL.lastPathComponent, privacy: .public)")
      }

      @MainActor
      private func prepareDrain(
        for session: WriterSession,
        targetSampleTime: Int64,
        logBuffers: Bool,
      ) {
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
      private func drain(_ session: WriterSession, notifyOnFailure: Bool) async {
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
          let error = WriterDrainTimeoutError(
            url: session.fileURL,
            timeout: owner.writerDrainTimeout,
          )
          session.control.cancelRequested.store(true, ordering: .relaxed)
          session.writer.close()
          let target = session.control.targetSampleTime.load(ordering: .relaxed)
          let written = session.control.writtenSampleTime.load(ordering: .relaxed)
          log.error(
            "⏱️ Writer drain timed out for \(session.fileURL.lastPathComponent, privacy: .public) after \(elapsed, privacy: .public): \(error, privacy: .public) target=\(target, privacy: .public) written=\(written, privacy: .public)",
          )
          recordFailure(ErrorContext(error), url: session.fileURL)
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
      package func enqueueDrain(for session: WriterSession) {
        let target = owner.recordingSampleTimeAtomic.load(ordering: .relaxed)
        prepareDrain(
          for: session,
          targetSampleTime: target,
          logBuffers: session.id == owner.recordingLifecycleState.writerSession?.id,
        )
        owner.recordingLifecycleState.drainingWriterSessions.append(session)
        owner.recordingCallbackTasks.run { [weak owner] in
          guard let owner else { return }
          await RecordingLifecycle(owner: owner).writer.drain(
            session,
            notifyOnFailure: true,
          )
          await MainActor.run {
            owner.recordingLifecycleState.drainingWriterSessions.removeAll {
              $0.id == session.id
            }
          }
        }
      }

      @MainActor
      func stopAndDrainAll(notifyOnFailure: Bool) async {
        if Task.isCancelled {
          log.warning("🧹 stopAndDrainAll cancelled before start")
          return
        }
        var sessions: [WriterSession] = []
        if let current = owner.recordingLifecycleState.writerSession {
          sessions.append(current)
        }
        sessions.append(contentsOf: owner.recordingLifecycleState.drainingWriterSessions)

        let target = owner.recordingSampleTimeAtomic.load(ordering: .relaxed)
        for session in sessions {
          if Task.isCancelled {
            log.warning("🧹 stopAndDrainAll cancelled before stop request")
            return
          }
          log.info(
            "🧹 Stop requested for writer \(session.fileURL.lastPathComponent, privacy: .public)",
          )
          prepareDrain(
            for: session,
            targetSampleTime: target,
            logBuffers: session.id == owner.recordingLifecycleState.writerSession?.id,
          )
        }
        for session in sessions {
          if Task.isCancelled {
            log.warning("🧹 stopAndDrainAll cancelled before drain wait")
            return
          }
          log.info("🧹 Drain wait start for \(session.fileURL.lastPathComponent, privacy: .public)")
          await drain(session, notifyOnFailure: notifyOnFailure)
        }

        owner.recordingLifecycleState.writerSession = nil
        owner.recordingLifecycleState.drainingWriterSessions.removeAll()
        log.info("🧹 stopAndDrainAll completed")
      }

      @MainActor
      func cancelAll() {
        if let current = owner.recordingLifecycleState.writerSession {
          current.control.cancelRequested.store(true, ordering: .relaxed)
        }
        for session in owner.recordingLifecycleState.drainingWriterSessions {
          session.control.cancelRequested.store(true, ordering: .relaxed)
        }
        owner.recordingLifecycleState.writerSession = nil
        owner.recordingLifecycleState.drainingWriterSessions.removeAll()
        log.info("🧹 cancelAllWriterSessions completed")
      }

      @MainActor
      func recordFailure(_ error: ErrorContext, url: URL?) {
        guard owner.recordingLifecycleState.lastWriteFailure == nil else { return }
        owner.recordingLifecycleState.lastWriteFailure = WriteFailure(url: url, error: error)
        log.error(
          "🛑 Recording write failed for \(url?.lastPathComponent ?? "missing URL", privacy: .public): \(error, privacy: .public)",
        )
      }

      @MainActor
      func consumeFailure() -> WriteFailure? {
        defer { owner.recordingLifecycleState.lastWriteFailure = nil }
        return owner.recordingLifecycleState.lastWriteFailure
      }

      nonisolated func isDrainTimeout(_ failure: WriteFailure) -> Bool {
        failure.error.domain.contains("WriterDrainTimeoutError")
          || failure.error.message.localizedCaseInsensitiveContains("writer drain timed out")
      }

      static func runLoop(
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
                if elapsed > .seconds(1),
                  lastStallLog.duration(to: clock.now) > .seconds(1)
                {
                  lastStallLog = clock.now
                  #if DEBUG
                    metrics.writerStallCount.wrappingIncrement(ordering: .relaxed)
                  #endif
                  let counts = audioBuffers.map(\.availableToRead)
                  let minAvailable = minimumAvailableFrames(
                    channelCount: Int(format.channelCount),
                    audioBuffers: audioBuffers,
                    limit: bufferSize,
                  )
                  log.warning(
                    "🧹 Writer stall after stop: elapsed=\(elapsed, privacy: .public) minAvail=\(minAvailable, privacy: .public) counts=\(counts, privacy: .public)",
                  )
                }
              }
              if shouldCancel() { break }
              let sleepMillis = stopRequested ? 1.0 : idleBackoffMillis
              Thread.sleep(forTimeInterval: sleepMillis / 1_000)
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
        for index in 0..<channelCount {
          guard let channelData = unsafe pcmBuffer.floatChannelData?[index] else {
            return .success(.init(framesRead: 0, writeDuration: nil))
          }
          let readSize = unsafe audioBuffers[index].read(
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

      package static func minimumAvailableWriteFrames(
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
    }
  }
#endif
