// © GoodHatsLLC

#if os(macOS)
  import AVFoundation
  import CoreAudio
  import Testing

  @testable import AIORecording

  struct SystemAudioSampleHandoffTests {
    private func sourceFormat() -> AVAudioFormat {
      // Non-interleaved float32 stereo — the canonical global-tap mixdown shape.
      AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    }

    /// Builds a source buffer with deterministic per-channel samples:
    /// channel c, frame i -> Float(i + c * 1000).
    private func makeInputBuffer(frames: Int, format: AVAudioFormat) -> AVAudioPCMBuffer {
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
      buffer.frameLength = AVAudioFrameCount(frames)
      let channels = Int(format.channelCount)
      for channel in 0..<channels {
        let data = unsafe buffer.floatChannelData![channel]
        for frame in 0..<frames {
          unsafe data[frame] = Float(frame + channel * 1000)
        }
      }
      return buffer
    }

    private func timestamp(hostTime: UInt64, sampleTime: Float64) -> AudioTimeStamp {
      // kAudioTimeStampSampleTimeValid = 1 << 0, kAudioTimeStampHostTimeValid = 1 << 1
      // (CoreAudioBaseTypes.h). Used as raw bits to avoid a CoreAudioTypes import.
      let sampleTimeValid: UInt32 = 1 << 0
      let hostTimeValid: UInt32 = 1 << 1
      var stamp = AudioTimeStamp()
      stamp.mHostTime = hostTime
      stamp.mSampleTime = sampleTime
      stamp.mRateScalar = 1.0
      stamp.mFlags = AudioTimeStampFlags(rawValue: hostTimeValid | sampleTimeValid)
      return stamp
    }

    @Test
    func `enqueue then drain preserves samples and timing`() {
      let format = sourceFormat()
      let handoff = SystemAudioSampleHandoff(
        sourceFormat: format,
        maxIOFrames: 512,
        capacitySeconds: 2.0,
      )!
      let frames = 256
      let input = makeInputBuffer(frames: frames, format: format)
      var stamp = timestamp(hostTime: 999_111, sampleTime: 4242)

      let enqueued = unsafe withUnsafePointer(to: &stamp) { stampPointer in
        unsafe handoff.enqueue(input.audioBufferList, timeStamp: stampPointer)
      }
      #expect(enqueued)

      let reusable = handoff.makeReusableBuffer(maxIOFrames: 512)!
      var captured: (frames: Int, host: UInt64?, hostValid: Bool, sample: AVAudioFramePosition?)?
      var firstChannelFirst: Float = .nan
      var firstChannelLast: Float = .nan
      var secondChannelFirst: Float = .nan

      let delivered = handoff.drainOne(into: reusable) { buffer, time in
        firstChannelFirst = unsafe buffer.floatChannelData![0][0]
        firstChannelLast = unsafe buffer.floatChannelData![0][frames - 1]
        secondChannelFirst = unsafe buffer.floatChannelData![1][0]
        captured = (
          frames: Int(buffer.frameLength),
          host: time.isHostTimeValid ? time.hostTime : nil,
          hostValid: time.isHostTimeValid,
          sample: time.isSampleTimeValid ? time.sampleTime : nil,
        )
      }

      #expect(delivered == frames)
      #expect(captured?.frames == frames)
      #expect(captured?.hostValid == true)
      #expect(captured?.host == 999_111)
      #expect(captured?.sample == 4242)
      #expect(firstChannelFirst == 0)
      #expect(firstChannelLast == Float(frames - 1))
      #expect(secondChannelFirst == 1000)
    }

    @Test
    func `drain returns zero when nothing is pending`() {
      let format = sourceFormat()
      let handoff = SystemAudioSampleHandoff(
        sourceFormat: format,
        maxIOFrames: 512,
        capacitySeconds: 2.0,
      )!
      let reusable = handoff.makeReusableBuffer(maxIOFrames: 512)!
      var sinkCalled = false
      let delivered = handoff.drainOne(into: reusable) { _, _ in sinkCalled = true }
      #expect(delivered == 0)
      #expect(!sinkCalled)
    }

    @Test
    func `enqueue drops (never blocks) when the ring is full and recovers after draining`() {
      let format = sourceFormat()
      // Tiny capacity so a couple of callbacks fill it.
      let handoff = SystemAudioSampleHandoff(
        sourceFormat: format,
        maxIOFrames: 256,
        capacitySeconds: 0.01,  // ~480 frames of headroom
      )!
      let input = makeInputBuffer(frames: 256, format: format)
      var stamp = timestamp(hostTime: 1, sampleTime: 0)

      var enqueuedCount = 0
      var droppedCount = 0
      for _ in 0..<10 {
        let ok = unsafe withUnsafePointer(to: &stamp) { stampPointer in
          unsafe handoff.enqueue(input.audioBufferList, timeStamp: stampPointer)
        }
        if ok { enqueuedCount += 1 } else { droppedCount += 1 }
      }
      // Some enqueued, then drops once full — and it never blocked/crashed.
      #expect(enqueuedCount >= 1)
      #expect(droppedCount >= 1)

      // After draining everything, enqueue succeeds again.
      let reusable = handoff.makeReusableBuffer(maxIOFrames: 256)!
      while handoff.drainOne(into: reusable, sink: { _, _ in }) > 0 {}
      let recovered = unsafe withUnsafePointer(to: &stamp) { stampPointer in
        unsafe handoff.enqueue(input.audioBufferList, timeStamp: stampPointer)
      }
      #expect(recovered)
    }
  }
#endif
