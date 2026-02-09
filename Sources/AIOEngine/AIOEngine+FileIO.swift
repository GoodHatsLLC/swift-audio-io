#if !os(macOS) || targetEnvironment(macCatalyst)
  import AVFoundation
  import AudioToolbox
  import Foundation
  import os
  import SystemLog
  import Tools

  private let log = SystemLog.make()

  extension AIOEngine: BufferEmitter {

    public typealias T = Float

    /// Attaches a buffer receiver to the engine.
    ///
    /// The receiver will receive real-time audio data while recording.
    ///
    /// - Parameter receiver: The buffer receiver to attach.
    public nonisolated func attachBufferReceiver(_ receiver: consuming some BufferReceiver<Float>)
      async
    {
      self.bufferReceivers({ $0.append(receiver) })
    }

    /// Detaches all buffer receivers from the engine.
    public nonisolated func detachBufferReceivers() async {
      self.bufferReceivers({ b in
        defer { b = [] }
        return b
      }).forEach {
        $0.endBufferTask()
      }
    }

    @MainActor
    func resolveOutputURL(
      for configuration: RecordingConfiguration,
      allowExplicitFile: Bool
    ) throws(AIOError) -> (url: URL, protection: OutputFileProtection?) {
      let filename = Self.generateRecordingFilename(extension: configuration.fileExtension)
      #if os(iOS)
        switch configuration.outputDestination {
        case .temporary:
          let resolved: (url: URL, protection: OutputFileProtection?) = (
            FileManager.default.temporaryDirectory.appendingPathComponent(
              filename, isDirectory: false),
            nil
          )
          logOutputDestination(configuration.outputDestination, url: resolved.0)
          return resolved
        case .directory(let directory, let protection):
          do {
            try FileManager.default.createDirectory(
              at: directory,
              withIntermediateDirectories: true
            )
          } catch {
            throw AIOError.audioFileFailed(
              operation: .openForWriting, url: directory, error: ErrorContext(error)
            )
          }
          applyFileProtectionIfNeeded(protection, to: directory)
          let resolved = (
            directory.appendingPathComponent(filename, isDirectory: false),
            protection
          )
          logOutputDestination(configuration.outputDestination, url: resolved.0)
          return resolved
        case .fileURL(let fileURL, let protection):
          guard allowExplicitFile else {
            throw AIOError.invalidRecordingConfiguration(
              details: "Output destination does not support rotation"
            )
          }
          let parent = fileURL.deletingLastPathComponent()
          do {
            try FileManager.default.createDirectory(
              at: parent,
              withIntermediateDirectories: true
            )
          } catch {
            throw AIOError.audioFileFailed(
              operation: .openForWriting, url: parent, error: ErrorContext(error)
            )
          }
          applyFileProtectionIfNeeded(protection, to: parent)
          let resolved = (fileURL, protection)
          logOutputDestination(configuration.outputDestination, url: resolved.0)
          return resolved
        }
      #else
        switch configuration.outputDestination {
        case .temporary:
          let resolved: (url: URL, protection: OutputFileProtection?) = (
            FileManager.default.temporaryDirectory.appendingPathComponent(
              filename, isDirectory: false),
            nil
          )
          logOutputDestination(configuration.outputDestination, url: resolved.0)
          return resolved
        case .directory(let directory):
          do {
            try FileManager.default.createDirectory(
              at: directory,
              withIntermediateDirectories: true
            )
          } catch {
            throw AIOError.audioFileFailed(
              operation: .openForWriting, url: directory, error: ErrorContext(error)
            )
          }
          let resolved: (url: URL, protection: OutputFileProtection?) = (
            directory.appendingPathComponent(filename, isDirectory: false),
            nil
          )
          logOutputDestination(configuration.outputDestination, url: resolved.0)
          return resolved
        case .fileURL(let fileURL):
          guard allowExplicitFile else {
            throw AIOError.invalidRecordingConfiguration(
              details: "Output destination does not support rotation"
            )
          }
          let parent = fileURL.deletingLastPathComponent()
          do {
            try FileManager.default.createDirectory(
              at: parent,
              withIntermediateDirectories: true
            )
          } catch {
            throw AIOError.audioFileFailed(
              operation: .openForWriting, url: parent, error: ErrorContext(error)
            )
          }
          let resolved: (url: URL, protection: OutputFileProtection?) = (fileURL, nil)
          logOutputDestination(configuration.outputDestination, url: resolved.0)
          return resolved
        }
      #endif
    }

    nonisolated func audioFileTypeID(for format: FileFormat) -> AudioFileTypeID {
      switch format {
      case .aac: return kAudioFileM4AType
      case .adts: return kAudioFileAAC_ADTSType
      case .wav: return kAudioFileWAVEType
      case .aiff: return kAudioFileAIFFType
      case .caf: return kAudioFileCAFType
      case .flac: return kAudioFileFLACType
      }
    }

    @MainActor
    func makeRecordingWriter(
      url: URL,
      configuration: RecordingConfiguration
    ) throws(AIOError) -> any RecordingFileWriter {
      guard let fileSettings = configuration.fileSettings else {
        throw AIOError.invalidRecordingConfiguration(details: "(file format settings)")
      }
      guard let processingFormat = configuration.processingFormat else {
        throw AIOError.invalidRecordingConfiguration(details: "processing format")
      }
      switch writerBackend {
      case .avAudioFile:
        do {
          let file = try AVAudioFile(forWriting: url, settings: fileSettings)
          return AVAudioFileWriter(file: file)
        } catch {
          throw AIOError.audioFileFailed(
            operation: .openForWriting, url: url, error: ErrorContext(error)
          )
        }
      case .extAudioFile:
        guard let outputFormat = AVAudioFormat(settings: fileSettings) else {
          throw AIOError.invalidRecordingConfiguration(details: "file format settings")
        }
        // ExtAudioFile ASBD describes the on-disk format, which must be interleaved
        // for multi-channel audio. The client format (processing) stays non-interleaved.
        let diskFormat: AVAudioFormat
        if !outputFormat.isInterleaved, outputFormat.channelCount > 1 {
          guard
            let interleaved = AVAudioFormat(
              commonFormat: outputFormat.commonFormat,
              sampleRate: outputFormat.sampleRate,
              channels: outputFormat.channelCount,
              interleaved: true
            )
          else {
            throw AIOError.invalidRecordingConfiguration(
              details: "interleaved file format settings")
          }
          diskFormat = interleaved
        } else {
          diskFormat = outputFormat
        }
        do {
          return try ExtAudioFileWriter(
            url: url,
            fileType: audioFileTypeID(for: configuration.outputConfiguration.fileFormat),
            outputFormat: diskFormat,
            clientFormat: processingFormat
          )
        } catch {
          throw AIOError.audioFileFailed(
            operation: .openForWriting, url: url, error: ErrorContext(error)
          )
        }
      }
    }

    @MainActor
    func applyFileProtectionIfNeeded(
      _ protection: OutputFileProtection?,
      to url: URL
    ) {
      #if os(iOS)
        guard let protection else { return }
        do {
          try FileManager.default.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: url.path
          )
        } catch {
          log.error(
            "🔒 Failed to apply file protection to \(url.path, privacy: .public): \(error, privacy: .public)"
          )
        }
      #else
        _ = protection
        _ = url
      #endif
    }

    nonisolated func fileSizeDescription(for url: URL) -> String {
      if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
        return "\(size)"
      }
      return "unknown"
    }

    nonisolated func fileSizeValue(for url: URL) -> Int? {
      (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    nonisolated func logOutputDestination(
      _ destination: RecordingConfiguration.OutputDestination,
      url: URL
    ) {
      log.info(
        "🎯 Recording output: destination=\(destination, privacy: .public) url=\(url.lastPathComponent, privacy: .public)"
      )
    }

    // MARK: - Filename Generation

    /// Generates a semantic filename for recordings.
    static func generateRecordingFilename(extension ext: String) -> String {
      RecordingFilename(fileExtension: ext).filename
    }
  }
#endif
