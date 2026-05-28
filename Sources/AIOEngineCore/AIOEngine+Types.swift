// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AVFoundation
  package import Foundation

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

  package struct PlaybackSegment: Equatable {
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

  package struct PlaybackResume: Equatable {
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

#endif
