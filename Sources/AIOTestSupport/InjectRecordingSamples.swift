// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOEngineCore
  import Atomics
  import AVFoundation
  import Foundation
  import Tools

  extension AIOEngine {
    /// Writes PCM into the recording pipeline exactly where the input tap
    /// would, so the writer and receiver loops observe genuine traffic.
    ///
    /// This is the one thing a fake capture backend cannot do through the
    /// public interface: real capture arrives via an `AVAudioEngine` tap
    /// callback, and there is no such callback without a graph. Everything
    /// after this point — backpressure accounting, timing packets, the sample
    /// clock, the drain — is the production path.
    ///
    /// Unlike the real tap, the whole operation — choosing the ring buffers,
    /// writing into them, and advancing the capture position — runs inside one
    /// `state` critical section. The tap cannot do that: it must never block on
    /// a lock, so it copies a snapshot and accounts for its frames afterwards.
    /// Holding the lock makes this seam a producer that *participates* in the
    /// engine's own synchronisation, which is what lets a test assert that a
    /// rotation's ring swap is atomic against such a producer.
    ///
    /// Returns whether the frames were accepted by the writer ring. `false`
    /// means the ring was full and the frames were dropped while the capture
    /// position still advanced — the same accounting the tap performs, and a
    /// signal that a test is producing faster than the writer drains.
    @discardableResult
    package nonisolated func injectRecordingSamples(
      channels: [[Float]],
      hostTime: UInt64? = nil,
      sourceSampleTime: Int64? = nil,
      sourceSampleRate: Double? = nil,
    ) -> Bool {
      guard !channels.isEmpty else { return false }
      let frameLength = channels.map(\.count).min() ?? 0
      guard frameLength > 0 else { return false }

      return state.withLock { state -> Bool in
        guard let audioBuffers = state.audioBuffers else { return false }
        let receiverBuffers = state.receiverBuffers
        let timingBuffer = state.receiverTiming

        let effectiveChannelCount = min(channels.count, audioBuffers.count)
        guard effectiveChannelCount > 0 else { return false }

        let writerAvailable = RecordingLifecycle.Writer.minimumAvailableWriteFrames(
          channelCount: effectiveChannelCount,
          audioBuffers: audioBuffers,
          limit: frameLength,
        )
        let writerCanWrite = writerAvailable >= frameLength

        let receiverCanWrite: Bool =
          if let receiverBuffers, let timingBuffer {
            timingBuffer.availableToWrite >= 1
              && RecordingLifecycle.Writer.minimumAvailableWriteFrames(
                channelCount: effectiveChannelCount,
                audioBuffers: receiverBuffers,
                limit: frameLength,
              ) >= frameLength
          } else {
            false
          }

        for i in 0..<effectiveChannelCount {
          channels[i].withUnsafeBufferPointer { buffer in
            if writerCanWrite {
              unsafe audioBuffers[i].write(buffer)
            }
            if receiverCanWrite, let receiverBuffers, i < receiverBuffers.count {
              unsafe receiverBuffers[i].write(buffer)
            }
          }
        }

        if writerCanWrite {
          recordPersistedBufferTiming(
            frameCount: frameLength,
            hostTime: hostTime,
            sourceSampleTime: sourceSampleTime,
          )
        }

        if receiverCanWrite, let timingBuffer {
          let startSampleTime = recordingSampleTimeAtomic.load(ordering: .relaxed)
          var packet = TimingPacket(
            startSampleTime: startSampleTime,
            frameCount: frameLength,
            hostTime: hostTime,
            sourceSampleTime: sourceSampleTime,
            sourceSampleRate: sourceSampleRate,
          )
          _ = withUnsafePointer(to: &packet) { pointer in
            unsafe timingBuffer.write(UnsafeBufferPointer(start: pointer, count: 1))
          }
        }

        recordingSampleTimeAtomic.wrappingIncrement(
          by: Int64(frameLength),
          ordering: .relaxed,
        )
        return writerCanWrite
      }
    }
  }
#endif
