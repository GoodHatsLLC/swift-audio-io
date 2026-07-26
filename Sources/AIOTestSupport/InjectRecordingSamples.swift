// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOEngineCore
  import AIORecording
  import AIORecordingSupport
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
    package nonisolated func injectRecordingSamples(
      channels: [[Float]],
      hostTime: UInt64? = nil,
      sourceSampleTime: Int64? = nil,
      sourceSampleRate: Double? = nil,
    ) {
      guard !channels.isEmpty else { return }
      let frameLength = channels.map(\.count).min() ?? 0
      guard frameLength > 0 else { return }

      let (audioBuffers, receiverBuffers, timingBuffer) = state.withLock { state in
        (state.audioBuffers, state.receiverBuffers, state.receiverTiming)
      }
      guard let audioBuffers else { return }

      let effectiveChannelCount = min(channels.count, audioBuffers.count)
      guard effectiveChannelCount > 0 else { return }

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
    }
  }
#endif
