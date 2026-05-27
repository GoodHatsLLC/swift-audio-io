// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOAudioSession
  import AIOContracts
  import AIOSupport
  import AIOEngineCore
  package import AIORecordingSupport
  import AudioToolbox
  import AVFoundation
  package import Foundation
  import os
  import Tools

  private let log = SystemLog.make()

  extension AIOEngine: BufferEmitter {
    public typealias T = Float

    @discardableResult
    public nonisolated func attachBufferReceiver(_ receiver: consuming some BufferReceiver<Float>)
      async -> BufferReceiverToken
    {
      let receivers = bufferReceivers
      let registeredReceiver = receiver as any BufferReceiver<Float>
      receivers { $0.append(registeredReceiver) }
      return BufferReceiverToken { [receivers, registeredReceiver] in
        let removedReceiver = receivers { registeredReceivers -> (any BufferReceiver<Float>)? in
          guard
            let index = registeredReceivers.firstIndex(where: {
              ($0 as AnyObject) === (registeredReceiver as AnyObject)
            })
          else {
            return nil
          }
          return registeredReceivers.remove(at: index)
        }
        removedReceiver?.endBufferTask()
      }
    }

    public nonisolated func detachBufferReceivers() async {
      for receiver in bufferReceivers({ receivers in
        defer { receivers = [] }
        return receivers
      }) {
        receiver.endBufferTask()
      }
    }

    @MainActor
    package func resolveOutputURL(
      for configuration: RecordingConfiguration,
      allowExplicitFile: Bool,
    ) throws(RecordingError) -> (url: URL, protection: OutputFileProtection?) {
      let filename = Self.generateRecordingFilename(extension: configuration.fileExtension)
      #if os(iOS)
        switch configuration.outputDestination {
        case .temporary:
          let resolved: (url: URL, protection: OutputFileProtection?) = (
            FileManager.default.temporaryDirectory.appendingPathComponent(
              filename, isDirectory: false,
            ),
            nil,
          )
          logOutputDestination(configuration.outputDestination, url: resolved.0)
          return resolved
        case .directory(let directory, let protection):
          do {
            try FileManager.default.createDirectory(
              at: directory,
              withIntermediateDirectories: true,
            )
          } catch {
            throw RecordingError.fileFailed(
              operation: .openForWriting, url: directory, error: ErrorContext(error),
            )
          }
          applyFileProtectionIfNeeded(protection, to: directory)
          let resolved = (
            directory.appendingPathComponent(filename, isDirectory: false),
            protection,
          )
          logOutputDestination(configuration.outputDestination, url: resolved.0)
          return resolved
        case .fileURL(let fileURL, let protection):
          guard allowExplicitFile else {
            throw RecordingError.invalidConfiguration(
              details: "Output destination does not support rotation",
            )
          }
          let parent = fileURL.deletingLastPathComponent()
          do {
            try FileManager.default.createDirectory(
              at: parent,
              withIntermediateDirectories: true,
            )
          } catch {
            throw RecordingError.fileFailed(
              operation: .openForWriting, url: parent, error: ErrorContext(error),
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
              filename, isDirectory: false,
            ),
            nil,
          )
          logOutputDestination(configuration.outputDestination, url: resolved.0)
          return resolved
        case .directory(let directory):
          do {
            try FileManager.default.createDirectory(
              at: directory,
              withIntermediateDirectories: true,
            )
          } catch {
            throw RecordingError.fileFailed(
              operation: .openForWriting, url: directory, error: ErrorContext(error),
            )
          }
          let resolved: (url: URL, protection: OutputFileProtection?) = (
            directory.appendingPathComponent(filename, isDirectory: false),
            nil,
          )
          logOutputDestination(configuration.outputDestination, url: resolved.0)
          return resolved
        case .fileURL(let fileURL):
          guard allowExplicitFile else {
            throw RecordingError.invalidConfiguration(
              details: "Output destination does not support rotation",
            )
          }
          let parent = fileURL.deletingLastPathComponent()
          do {
            try FileManager.default.createDirectory(
              at: parent,
              withIntermediateDirectories: true,
            )
          } catch {
            throw RecordingError.fileFailed(
              operation: .openForWriting, url: parent, error: ErrorContext(error),
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
      case .aac: kAudioFileM4AType
      case .adts: kAudioFileAAC_ADTSType
      case .wav: kAudioFileWAVEType
      case .aiff: kAudioFileAIFFType
      case .caf: kAudioFileCAFType
      case .flac: kAudioFileFLACType
      }
    }

    @MainActor
    package func makeRecordingWriter(
      url: URL,
      configuration: RecordingConfiguration,
    ) throws(RecordingError) -> any RecordingFileWriter {
      guard let fileSettings = configuration.fileSettings else {
        throw RecordingError.invalidConfiguration(details: "(file format settings)")
      }
      guard let processingFormat = configuration.processingFormat else {
        throw RecordingError.invalidConfiguration(details: "processing format")
      }
      switch writerBackend {
      case .avAudioFile:
        do {
          let file = try AVAudioFile(forWriting: url, settings: fileSettings)
          return AVAudioFileWriter(file: file)
        } catch {
          throw RecordingError.fileFailed(
            operation: .openForWriting, url: url, error: ErrorContext(error),
          )
        }
      case .extAudioFile:
        guard let outputFormat = AVAudioFormat(settings: fileSettings) else {
          throw RecordingError.invalidConfiguration(details: "file format settings")
        }
        let diskFormat: AVAudioFormat
        if !outputFormat.isInterleaved, outputFormat.channelCount > 1 {
          guard let channelLayout = outputFormat.channelLayout else {
            throw RecordingError.invalidConfiguration(
              details: "file format channel layout",
            )
          }
          diskFormat = AVAudioFormat(
            commonFormat: outputFormat.commonFormat,
            sampleRate: outputFormat.sampleRate,
            interleaved: true,
            channelLayout: channelLayout,
          )
        } else {
          diskFormat = outputFormat
        }
        do {
          return try ExtAudioFileWriter(
            url: url,
            fileType: audioFileTypeID(for: configuration.outputConfiguration.fileFormat),
            outputFormat: diskFormat,
            clientFormat: processingFormat,
          )
        } catch {
          throw RecordingError.fileFailed(
            operation: .openForWriting, url: url, error: ErrorContext(error),
          )
        }
      }
    }

    @MainActor
    package func applyFileProtectionIfNeeded(
      _ protection: OutputFileProtection?,
      to url: URL,
    ) {
      #if os(iOS)
        guard let protection else { return }
        do {
          try FileManager.default.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: url.path,
          )
        } catch {
          log.error(
            "🔒 Failed to apply file protection to \(url.path, privacy: .public): \(error, privacy: .public)",
          )
        }
      #else
        _ = protection
        _ = url
      #endif
    }

    package nonisolated func fileSizeDescription(for url: URL) -> String {
      if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
        return "\(size)"
      }
      return "unknown"
    }

    package nonisolated func fileSizeValue(for url: URL) -> Int? {
      (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    nonisolated func logOutputDestination(
      _ destination: RecordingConfiguration.OutputDestination,
      url: URL,
    ) {
      log.info(
        "🎯 Recording output: destination=\(destination, privacy: .public) url=\(url.lastPathComponent, privacy: .public)",
      )
    }

    static func generateRecordingFilename(extension ext: String) -> String {
      RecordingFilename(fileExtension: ext).filename
    }
  }
#endif
