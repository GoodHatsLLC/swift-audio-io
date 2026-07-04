// © GoodHatsLLC

#if canImport(AVFoundation)
  package import Atomics
  package import AVFoundation
  package import Foundation

  public struct PlaybackJogRate: Hashable, Sendable {
    public var value: Double

    public init(_ value: Double) {
      self.value = value
    }

    public static let paused = PlaybackJogRate(0)
    public static let normalForward = PlaybackJogRate(1)
    public static let normalReverse = PlaybackJogRate(-1)
  }

  public struct PlaybackJogSnapshot: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let file: URL
    public let time: TimeInterval
    public let duration: TimeInterval
    public let rate: Double
    public let isAudible: Bool

    public init(
      id: UUID,
      file: URL,
      time: TimeInterval,
      duration: TimeInterval,
      rate: Double,
      isAudible: Bool,
    ) {
      self.id = id
      self.file = file
      self.time = time
      self.duration = duration
      self.rate = rate
      self.isAudible = isAudible
    }
  }

  package struct EmptyAudioFileError: LocalizedError, Equatable {
    package init(url: URL) {
      self.url = url
    }

    package let url: URL

    package var errorDescription: String? {
      "Audio file is empty: \(url.lastPathComponent)"
    }
  }

  package struct MissingAudioFileError: LocalizedError, Equatable {
    package init(url: URL) {
      self.url = url
    }

    package let url: URL

    package var errorDescription: String? {
      "Audio file is missing: \(url.lastPathComponent)"
    }
  }

  package struct PlaybackRuntimeState {
    package var playbackInstance: PlaybackInstance?
    package var playbackJogInstance: PlaybackJogInstance?
    /// The most recent position derived from a live node render, kept so a
    /// paused node (which can't report `lastRenderTime`) reports where it
    /// actually sits instead of snapping back to the segment start frame.
    package var lastObservedPlaybackTime: ObservedPlaybackTime?
  }

  package struct ObservedPlaybackTime: Equatable {
    package init(instanceID: UUID, time: TimeInterval) {
      self.instanceID = instanceID
      self.time = time
    }

    package let instanceID: UUID
    package let time: TimeInterval
  }

  package struct PlaybackSegment: Equatable, Sendable {
    package init(
      startFrame: AVAudioFramePosition,
      frameCount: AVAudioFrameCount,
    ) {
      self.startFrame = startFrame
      self.frameCount = frameCount
    }

    package let startFrame: AVAudioFramePosition
    package let frameCount: AVAudioFrameCount

    package var endFrame: AVAudioFramePosition {
      startFrame + AVAudioFramePosition(frameCount)
    }

    package func duration(sampleRate: Double) -> TimeInterval {
      Double(frameCount) / sampleRate
    }

    package func clampedAbsoluteFrame(
      forRelativeTime time: TimeInterval,
      sampleRate: Double,
    ) -> AVAudioFramePosition {
      let requestedOffset = AVAudioFramePosition(time * sampleRate)
      let requestedFrame = startFrame + requestedOffset
      return min(max(requestedFrame, startFrame), max(startFrame, endFrame - 1))
    }

    package func relativeTime(
      forAbsoluteFrame frame: AVAudioFramePosition,
      sampleRate: Double,
    ) -> TimeInterval {
      Double(frame - startFrame) / sampleRate
    }

    package func remainingFrameCount(
      from frame: AVAudioFramePosition,
    ) -> AVAudioFrameCount {
      AVAudioFrameCount(max(0, endFrame - frame))
    }
  }

  package struct PlaybackInstance: Identifiable {
    package init(
      id: UUID,
      file: AVAudioFile,
      startFrame: AVAudioFramePosition,
      pollingInterval: Duration,
      activeSegment: PlaybackSegment? = nil,
      onComplete: (@MainActor @Sendable () -> Void)? = nil,
    ) {
      self.id = id
      self.file = file
      self.startFrame = startFrame
      self.pollingInterval = pollingInterval
      self.activeSegment = activeSegment
      self.onComplete = onComplete
    }

    package let id: UUID
    package let file: AVAudioFile
    package let startFrame: AVAudioFramePosition
    package let pollingInterval: Duration
    package let activeSegment: PlaybackSegment?
    package let onComplete: (@MainActor @Sendable () -> Void)?

    package func playbackTime(
      forAbsoluteFrame frame: AVAudioFramePosition,
    ) -> TimeInterval {
      let sampleRate = file.processingFormat.sampleRate
      if let activeSegment {
        return activeSegment.relativeTime(forAbsoluteFrame: frame, sampleRate: sampleRate)
      }
      return Double(frame) / sampleRate
    }

    package var duration: TimeInterval {
      let sampleRate = file.processingFormat.sampleRate
      if let activeSegment {
        return activeSegment.duration(sampleRate: sampleRate)
      }
      return Double(file.length) / sampleRate
    }

    package var scheduledFrameCount: AVAudioFrameCount {
      if let activeSegment {
        return activeSegment.remainingFrameCount(from: startFrame)
      }
      return AVAudioFrameCount(max(0, file.length - startFrame))
    }
  }

  package struct PlaybackResume: Equatable, Sendable {
    package init(
      fileURL: URL,
      time: TimeInterval,
      duration: TimeInterval,
      wasPlaying: Bool,
      pollingInterval: Duration,
      activeSegment: PlaybackSegment? = nil,
      sampleRate: Double,
    ) {
      self.fileURL = fileURL
      self.time = time
      self.duration = duration
      self.wasPlaying = wasPlaying
      self.pollingInterval = pollingInterval
      self.activeSegment = activeSegment
      self.sampleRate = sampleRate
    }

    package let fileURL: URL
    package let time: TimeInterval
    package let duration: TimeInterval
    package let wasPlaying: Bool
    package let pollingInterval: Duration
    package let activeSegment: PlaybackSegment?
    package let sampleRate: Double
  }

  package struct PlaybackJogDecodeRequest: Sendable {
    package init(
      fileURL: URL,
      lowerBoundFrame: AVAudioFramePosition,
      upperBoundFrame: AVAudioFramePosition,
      cursorFrame: Double,
    ) {
      self.fileURL = fileURL
      self.lowerBoundFrame = lowerBoundFrame
      self.upperBoundFrame = upperBoundFrame
      self.cursorFrame = cursorFrame
    }

    package let fileURL: URL
    package let lowerBoundFrame: AVAudioFramePosition
    package let upperBoundFrame: AVAudioFramePosition
    package let cursorFrame: Double
  }

  package struct PlaybackJogPreparedAudio: Sendable {
    package init(
      pcm: PlaybackJogPCMStore,
      sampleRate: Double,
      channelCount: Int,
    ) {
      self.pcm = pcm
      self.sampleRate = sampleRate
      self.channelCount = channelCount
    }

    package let pcm: PlaybackJogPCMStore
    package let sampleRate: Double
    package let channelCount: Int
  }

  package struct PlaybackJogInstance: Identifiable, Sendable {
    package init(
      id: UUID,
      fileURL: URL,
      activeSegment: PlaybackSegment?,
      duration: TimeInterval,
      originalPlayback: PlaybackResume,
      sampleRate: Double,
      lowerBoundFrame: AVAudioFramePosition,
      upperBoundFrame: AVAudioFramePosition,
      cursorFrame: Double,
      rate: Double = 0,
      renderState: PlaybackJogRenderState? = nil,
    ) {
      self.id = id
      self.fileURL = fileURL
      self.activeSegment = activeSegment
      self.duration = duration
      self.originalPlayback = originalPlayback
      self.sampleRate = sampleRate
      self.lowerBoundFrame = lowerBoundFrame
      self.upperBoundFrame = upperBoundFrame
      self.cursorFrame = cursorFrame
      self.rate = rate
      self.renderState = renderState
    }

    package let id: UUID
    package let fileURL: URL
    package let activeSegment: PlaybackSegment?
    package let duration: TimeInterval
    package let originalPlayback: PlaybackResume
    package let sampleRate: Double
    package let lowerBoundFrame: AVAudioFramePosition
    package let upperBoundFrame: AVAudioFramePosition
    package var cursorFrame: Double
    package var rate: Double
    package var renderState: PlaybackJogRenderState?

    package var decodeRequest: PlaybackJogDecodeRequest {
      PlaybackJogDecodeRequest(
        fileURL: fileURL,
        lowerBoundFrame: lowerBoundFrame,
        upperBoundFrame: upperBoundFrame,
        cursorFrame: currentCursorFrame,
      )
    }

    package var currentCursorFrame: Double {
      renderState?.cursorFrame ?? cursorFrame
    }

    package func clampedFrame(_ frame: Double) -> Double {
      let lower = Double(lowerBoundFrame)
      let upper = Double(max(lowerBoundFrame, upperBoundFrame - 1))
      return min(max(frame, lower), upper)
    }

    package func publicTime(forAbsoluteFrame frame: Double) -> TimeInterval {
      if let activeSegment {
        return (clampedFrame(frame) - Double(activeSegment.startFrame)) / sampleRate
      }
      return clampedFrame(frame) / sampleRate
    }

    package func snapshot() -> PlaybackJogSnapshot {
      let renderState = renderState
      let frame = renderState?.cursorFrame ?? cursorFrame
      let rate = renderState?.rate ?? rate
      return PlaybackJogSnapshot(
        id: id,
        file: fileURL,
        time: publicTime(forAbsoluteFrame: frame),
        duration: duration,
        rate: rate,
        isAudible: renderState?.isAudible ?? false,
      )
    }
  }

  package struct PlaybackJogPCMStore: Sendable {
    package init(
      baseFrame: AVAudioFramePosition,
      channels: [[Float]],
    ) {
      self.baseFrame = baseFrame
      self.channels = channels
      self.frameCount = channels.first?.count ?? 0
    }

    package let baseFrame: AVAudioFramePosition
    package let channels: [[Float]]
    package let frameCount: Int

    package var endFrame: AVAudioFramePosition {
      baseFrame + AVAudioFramePosition(frameCount)
    }

    package func sample(channel: Int, frame: Double) -> Float? {
      guard !channels.isEmpty, frameCount > 0 else { return nil }
      let source = channels[min(max(channel, 0), channels.count - 1)]
      let relative = frame - Double(baseFrame)
      guard relative >= 0, relative < Double(frameCount) else { return nil }

      let lowerIndex = Int(relative.rounded(.down))
      let upperIndex = min(lowerIndex + 1, frameCount - 1)
      let fraction = Float(relative - Double(lowerIndex))
      let lower = source[lowerIndex]
      let upper = source[upperIndex]
      return lower + ((upper - lower) * fraction)
    }
  }

  // SAFETY: all mutable fields are ManagedAtomic. The PCM store is immutable
  // after initialization and graph mutation is owned by AIOEngine's
  // engineControlQueue.
  package final class PlaybackJogRenderState: @unchecked Sendable {
    package init(
      cursorFrame: Double,
      rate: Double,
      lowerBoundFrame: AVAudioFramePosition,
      upperBoundFrame: AVAudioFramePosition,
      sourceSampleRate: Double,
      channels: Int,
      pcm: PlaybackJogPCMStore,
    ) {
      cursorFrameBits = ManagedAtomic(cursorFrame.bitPattern)
      rateBits = ManagedAtomic(rate.bitPattern)
      effectiveRateBits = ManagedAtomic(rate.bitPattern)
      pendingAnchorFrameBits = ManagedAtomic(cursorFrame.bitPattern)
      pendingAnchorSequence = ManagedAtomic(0)
      consumedAnchorSequence = ManagedAtomic(0)
      isAudibleAtomic = ManagedAtomic(false)
      self.lowerBoundFrame = lowerBoundFrame
      self.upperBoundFrame = upperBoundFrame
      self.sourceSampleRate = sourceSampleRate
      self.channels = channels
      self.pcm = pcm
    }

    package let cursorFrameBits: ManagedAtomic<UInt64>
    package let rateBits: ManagedAtomic<UInt64>
    package let effectiveRateBits: ManagedAtomic<UInt64>
    package let pendingAnchorFrameBits: ManagedAtomic<UInt64>
    package let pendingAnchorSequence: ManagedAtomic<UInt64>
    package let consumedAnchorSequence: ManagedAtomic<UInt64>
    package let isAudibleAtomic: ManagedAtomic<Bool>
    package let lowerBoundFrame: AVAudioFramePosition
    package let upperBoundFrame: AVAudioFramePosition
    package let sourceSampleRate: Double
    package let channels: Int
    package let pcm: PlaybackJogPCMStore

    package var cursorFrame: Double {
      loadAtomicDouble(cursorFrameBits)
    }

    package var rate: Double {
      loadAtomicDouble(rateBits)
    }

    package var isAudible: Bool {
      isAudibleAtomic.load(ordering: .relaxed)
    }

    package func setRate(_ rate: Double) {
      storeAtomicDouble(rate, in: rateBits)
    }

    package func publishAnchor(frame: Double) {
      storeAtomicDouble(clampedFrame(frame), in: pendingAnchorFrameBits)
      pendingAnchorSequence.wrappingIncrement(ordering: .releasing)
    }

    package func stop() {
      setRate(0)
      storeAtomicDouble(0, in: effectiveRateBits)
      isAudibleAtomic.store(false, ordering: .relaxed)
    }

    package func clampedFrame(_ frame: Double) -> Double {
      let lower = Double(lowerBoundFrame)
      let upper = Double(max(lowerBoundFrame, upperBoundFrame - 1))
      return min(max(frame, lower), upper)
    }

    @discardableResult
    package func render(
      frameCount: AVAudioFrameCount,
      outputData: UnsafeMutablePointer<AudioBufferList>,
    ) -> OSStatus {
      let outputFrames = Int(frameCount)
      guard outputFrames > 0 else { return noErr }

      let pendingSequence = pendingAnchorSequence.load(ordering: .acquiring)
      var cursor = loadAtomicDouble(cursorFrameBits)
      if pendingSequence != consumedAnchorSequence.load(ordering: .relaxed) {
        let anchor = loadAtomicDouble(pendingAnchorFrameBits)
        let delta = anchor - cursor
        if abs(delta) > sourceSampleRate * 0.25 {
          cursor = clampedFrame(anchor)
        } else {
          cursor = clampedFrame(cursor + (delta * 0.35))
        }
        consumedAnchorSequence.store(pendingSequence, ordering: .releasing)
      }

      let targetRate = loadAtomicDouble(rateBits)
      var effectiveRate = loadAtomicDouble(effectiveRateBits)
      let rateStep = (targetRate - effectiveRate) / Double(outputFrames)
      var renderedAudibleSample = false
      let lower = Double(lowerBoundFrame)
      let upper = Double(max(lowerBoundFrame, upperBoundFrame - 1))

      let buffers = unsafe UnsafeMutableAudioBufferListPointer(outputData)
      for bufferIndex in buffers.indices {
        guard let data = unsafe buffers[bufferIndex].mData else { continue }
        let channelsInBuffer = max(1, Int(unsafe buffers[bufferIndex].mNumberChannels))
        let writableFrames =
          min(
            outputFrames,
            Int(unsafe buffers[bufferIndex].mDataByteSize)
              / (MemoryLayout<Float>.stride * channelsInBuffer),
          )
        let samples = unsafe data.assumingMemoryBound(to: Float.self)
        for frameIndex in 0..<writableFrames {
          for channelOffset in 0..<channelsInBuffer {
            unsafe samples[(frameIndex * channelsInBuffer) + channelOffset] = 0
          }
        }
      }

      for frameIndex in 0..<outputFrames {
        let readFrame = clampedFrame(cursor)
        let movingOutward =
          (cursor <= lower && effectiveRate < 0) || (cursor >= upper && effectiveRate > 0)
        let sourceAvailable = !movingOutward && cursor >= lower && cursor <= upper

        for bufferIndex in buffers.indices {
          guard let data = unsafe buffers[bufferIndex].mData else { continue }
          let channelsInBuffer = max(1, Int(unsafe buffers[bufferIndex].mNumberChannels))
          let writableFrames =
            Int(unsafe buffers[bufferIndex].mDataByteSize)
              / (MemoryLayout<Float>.stride * channelsInBuffer)
          guard frameIndex < writableFrames else { continue }
          let samples = unsafe data.assumingMemoryBound(to: Float.self)
          for channelOffset in 0..<channelsInBuffer {
            let sourceChannel = buffers.count == 1 ? channelOffset : bufferIndex
            let sample =
              sourceAvailable
              ? (pcm.sample(channel: sourceChannel, frame: readFrame) ?? 0)
              : 0
            if sample != 0 { renderedAudibleSample = true }
            unsafe samples[(frameIndex * channelsInBuffer) + channelOffset] = sample
          }
        }

        effectiveRate += rateStep
        cursor = clampedFrame(cursor + effectiveRate)
      }

      storeAtomicDouble(cursor, in: cursorFrameBits)
      storeAtomicDouble(effectiveRate, in: effectiveRateBits)
      isAudibleAtomic.store(renderedAudibleSample || abs(targetRate) > 0, ordering: .relaxed)
      return noErr
    }
  }

  package func loadAtomicDouble(_ atomic: ManagedAtomic<UInt64>) -> Double {
    Double(bitPattern: atomic.load(ordering: .relaxed))
  }

  package func storeAtomicDouble(_ value: Double, in atomic: ManagedAtomic<UInt64>) {
    atomic.store(value.bitPattern, ordering: .relaxed)
  }

#endif
