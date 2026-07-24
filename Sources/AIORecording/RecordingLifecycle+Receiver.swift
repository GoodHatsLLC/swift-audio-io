// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOContracts
  import AIOEngineCore
  package import AIORecordingSupport
  import Atomics
  package import AVFoundation
  import Foundation
  import Tools

  extension RecordingLifecycle {
    package var receiver: Receiver {
      Receiver(owner: owner)
    }

    package struct Receiver {
      let owner: AIOEngine

      @MainActor
      package func start(
        buffers: [SPSCRingBuffer<Float>],
        timing: SPSCRingBuffer<TimingPacket>,
        format: AVAudioFormat,
      ) {
        stop()
        let control = ReceiverControl()
        let session = ReceiverSession(
          id: UUID(),
          control: control,
          buffers: buffers,
          timing: timing,
          processingFormat: format,
        )
        owner.recordingLifecycleState.receiverSession = session
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
          Self.runLoop(
            buffers: buffers,
            timing: timing,
            processingFormat: format,
            bufferReceivers: owner.bufferReceivers,
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
      func stop() {
        guard let session = owner.recordingLifecycleState.receiverSession else { return }
        session.control.cancelRequested.store(true, ordering: .relaxed)
        owner.recordingLifecycleState.receiverSession = nil
      }

      static func runLoop(
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
        func deallocateScratchBuffers() {
          let count = unsafe scratchBuffers.count
          for index in 0..<count {
            unsafe scratchBuffers[index].baseAddress?.deallocate()
          }
        }
        func ensureScratchCapacity(_ needed: Int) {
          guard needed > scratchCapacity else { return }
          deallocateScratchBuffers()
          unsafe scratchBuffers = unsafe (0..<channelCount).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: needed)
            return unsafe UnsafeMutableBufferPointer(start: pointer, count: needed)
          }
          scratchCapacity = needed
        }
        defer {
          deallocateScratchBuffers()
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
    }
  }
#endif
