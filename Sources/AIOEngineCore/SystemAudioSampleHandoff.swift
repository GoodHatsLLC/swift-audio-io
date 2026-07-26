// © GoodHatsLLC

#if os(macOS)
  import Atomics
  package import AVFoundation
  import Tools

  /// Per-callback timing captured from the IOProc's `inInputTime`, carried
  /// alongside the audio bytes so the source pump can rebuild an `AVAudioTime`.
  package struct SystemAudioTimingPacket: Equatable {
    package var frameCount: UInt32
    package var hostTime: UInt64
    package var sampleTime: Float64
    package var rateScalar: Float64
    /// `AudioTimeStampFlags` raw value (host-time / sample-time validity).
    package var flags: UInt32

    package init(
      frameCount: UInt32 = 0,
      hostTime: UInt64 = 0,
      sampleTime: Float64 = 0,
      rateScalar: Float64 = 0,
      flags: UInt32 = 0,
    ) {
      self.frameCount = frameCount
      self.hostTime = hostTime
      self.sampleTime = sampleTime
      self.rateScalar = rateScalar
      self.flags = flags
    }
  }

  /// Lock-free, pre-allocated handoff between the realtime Core Audio IOProc
  /// (single producer) and the non-realtime source pump (single consumer).
  ///
  /// The IOProc side (`enqueue`) does only bounded `memcpy`s into pre-allocated
  /// `SPSCRingBuffer`s plus an `AudioTimeStamp` copy — no allocation, no locks,
  /// no `DispatchQueue`, no `AVAudioConverter`. On overflow it drops the whole
  /// callback (audio + timing together, keeping the two rings frame-aligned) and
  /// never blocks. The pump side (`drainOne`) rebuilds the source-format buffer
  /// and timing off the realtime thread and hands them to a sink that calls the
  /// shared `processAudio` path.
  // SAFETY: SPSC — exactly one realtime producer and one non-realtime consumer.
  package final class SystemAudioSampleHandoff: @unchecked Sendable {
    package let sourceFormat: AVAudioFormat

    /// Number of `AudioBuffer`s per callback in the source layout (channels when
    /// non-interleaved, else 1) and the bytes-per-frame stride of each.
    private let bufferCount: Int
    private let bufferStride: Int

    private let byteRing: SPSCRingBuffer<UInt8>
    private let timingRing: SPSCRingBuffer<SystemAudioTimingPacket>

    #if DEBUG
      package let dropCount = ManagedAtomicCounter()
    #endif

    package init?(
      sourceFormat: AVAudioFormat,
      maxIOFrames: Int,
      capacitySeconds: Double,
    ) {
      let asbd = unsafe sourceFormat.streamDescription.pointee
      let stride = Int(asbd.mBytesPerFrame)
      guard stride > 0, maxIOFrames > 0 else { return nil }
      let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
      let channelCount = max(1, Int(asbd.mChannelsPerFrame))

      self.sourceFormat = sourceFormat
      bufferCount = nonInterleaved ? channelCount : 1
      bufferStride = stride

      let bytesPerFrameTotal = bufferCount * stride
      let ringFrames = max(maxIOFrames, Int(sourceFormat.sampleRate * capacitySeconds))
      byteRing = SPSCRingBuffer<UInt8>(capacity: max(1, ringFrames * bytesPerFrameTotal))

      let framesPerCallback = max(1, maxIOFrames)
      let timingCapacity = max(64, Int(ceil(sourceFormat.sampleRate / Double(framesPerCallback))) * 4)
      timingRing = SPSCRingBuffer<SystemAudioTimingPacket>(capacity: timingCapacity)
    }

    /// Realtime-thread producer. Copies every channel of `bufferList` plus the
    /// timestamp into the rings. Returns `true` if enqueued, `false` if dropped
    /// (rings full). Never allocates or blocks.
    @discardableResult
    package func enqueue(
      _ bufferList: UnsafePointer<AudioBufferList>,
      timeStamp: UnsafePointer<AudioTimeStamp>,
    ) -> Bool {
      let buffers = unsafe UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: bufferList),
      )
      let bufferCount = buffers.count
      guard bufferCount > 0 else { return false }
      let firstBytes = unsafe Int(buffers[0].mDataByteSize)
      guard firstBytes > 0 else { return false }
      let frameCount = firstBytes / bufferStride
      guard frameCount > 0 else { return false }

      var totalBytes = 0
      for index in 0..<bufferCount {
        totalBytes += unsafe Int(buffers[index].mDataByteSize)
      }

      // All-or-nothing: only enqueue if both rings can take the whole callback,
      // so the consumer never sees a timing packet without its audio bytes.
      guard byteRing.availableToWrite >= totalBytes, timingRing.availableToWrite >= 1 else {
        #if DEBUG
          dropCount.increment()
        #endif
        return false
      }

      for index in 0..<bufferCount {
        let byteSize = unsafe Int(buffers[index].mDataByteSize)
        guard let data = unsafe buffers[index].mData, byteSize > 0 else { continue }
        let bytes = unsafe UnsafeBufferPointer(
          start: data.assumingMemoryBound(to: UInt8.self),
          count: byteSize,
        )
        unsafe byteRing.write(bytes)
      }

      let stamp = unsafe timeStamp.pointee
      var packet = SystemAudioTimingPacket(
        frameCount: UInt32(frameCount),
        hostTime: stamp.mHostTime,
        sampleTime: stamp.mSampleTime,
        rateScalar: stamp.mRateScalar,
        flags: stamp.mFlags.rawValue,
      )
      _ = unsafe withUnsafePointer(to: &packet) { pointer in
        unsafe timingRing.write(UnsafeBufferPointer(start: pointer, count: 1))
      }
      return true
    }

    /// Non-realtime consumer. Drains one callback into `buffer` (reused across
    /// calls; must be a `sourceFormat` buffer with capacity ≥ the IOProc buffer
    /// size), rebuilds the `AVAudioTime`, and invokes `sink`. Returns the number
    /// of frames delivered, or `0` if nothing was pending / a partial read
    /// occurred.
    @discardableResult
    package func drainOne(
      into buffer: AVAudioPCMBuffer,
      sink: (AVAudioPCMBuffer, AVAudioTime) -> Void,
    ) -> Int {
      var packet = SystemAudioTimingPacket()
      let read = unsafe withUnsafeMutablePointer(to: &packet) { pointer in
        unsafe timingRing.read(into: UnsafeMutableBufferPointer(start: pointer, count: 1))
      }
      guard read == 1, packet.frameCount > 0 else { return 0 }
      let frameCount = Int(packet.frameCount)
      guard frameCount <= Int(buffer.frameCapacity) else { return 0 }

      buffer.frameLength = AVAudioFrameCount(frameCount)
      let destination = unsafe UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
      let want = frameCount * bufferStride
      for index in destination.indices {
        guard let data = unsafe destination[index].mData else { return 0 }
        let readBytes = unsafe byteRing.read(
          into: UnsafeMutableBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: want,
          ),
        )
        guard readBytes == want else { return 0 }
        unsafe destination[index].mDataByteSize = UInt32(want)
      }

      var stamp = AudioTimeStamp()
      stamp.mHostTime = packet.hostTime
      stamp.mSampleTime = packet.sampleTime
      stamp.mRateScalar = packet.rateScalar
      stamp.mFlags = AudioTimeStampFlags(rawValue: packet.flags)
      let time = unsafe withUnsafePointer(to: &stamp) { pointer in
        unsafe AVAudioTime(audioTimeStamp: pointer, sampleRate: sourceFormat.sampleRate)
      }
      sink(buffer, time)
      return frameCount
    }

    /// A reusable source-format buffer sized for the IOProc buffer, for the pump.
    package func makeReusableBuffer(maxIOFrames: Int) -> AVAudioPCMBuffer? {
      AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(maxIOFrames))
    }
  }

  /// Minimal `Sendable` atomic counter for debug drop metrics, mirroring the
  /// existing recording metrics style without pulling in a heavier dependency.
  // SAFETY: backed by an atomic.
  package final class ManagedAtomicCounter: @unchecked Sendable {
    private let value = ManagedAtomic<Int64>(0)
    package init() {}
    package func increment() { value.wrappingIncrement(ordering: .relaxed) }
    package var load: Int64 { value.load(ordering: .relaxed) }
  }
#endif
