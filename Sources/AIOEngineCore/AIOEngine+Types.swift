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
  }

  package struct PlaybackInstance: Identifiable {
    package init(
      id: UUID,
      file: AVAudioFile,
      startFrame: AVAudioFramePosition,
      pollingInterval: Duration,
    ) {
      self.id = id
      self.file = file
      self.startFrame = startFrame
      self.pollingInterval = pollingInterval
    }

    package let id: UUID
    package let file: AVAudioFile
    package let startFrame: AVAudioFramePosition
    package let pollingInterval: Duration
  }

  package struct PlaybackResume: Equatable {
    package init(
      fileURL: URL,
      time: TimeInterval,
      duration: TimeInterval,
      wasPlaying: Bool,
      pollingInterval: Duration,
    ) {
      self.fileURL = fileURL
      self.time = time
      self.duration = duration
      self.wasPlaying = wasPlaying
      self.pollingInterval = pollingInterval
    }

    package let fileURL: URL
    package let time: TimeInterval
    package let duration: TimeInterval
    package let wasPlaying: Bool
    package let pollingInterval: Duration
  }

#endif
