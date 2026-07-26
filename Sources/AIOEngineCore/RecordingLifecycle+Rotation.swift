// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOSupport
  import Atomics
  import AVFoundation
  import Foundation
  import os
  import Tools

  private let log = SystemLog.make()

  extension RecordingLifecycle {
    var rotation: Rotation {
      Rotation(owner: owner)
    }

    struct Rotation {
      let owner: AIOEngine

      /// Resolves and opens the next recording file away from the main actor.
      @concurrent
      private nonisolated func prepareFile(
        configuration: RecordingConfiguration,
        writerBackend: WriterBackend,
      ) async throws(RecordingError) -> (writer: any RecordingFileWriter, url: URL) {
        #if DEBUG
          dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        let (newURL, protection): (URL, OutputFileProtection?) = try owner.resolveOutputURL(
          for: configuration,
          allowExplicitFile: false,
        )
        let newWriter = try owner.makeRecordingWriter(
          url: newURL,
          configuration: configuration,
          writerBackend: writerBackend,
        )
        owner.applyFileProtectionIfNeeded(protection, to: newURL)
        return (newWriter, newURL)
      }

      /// Closes and removes a prepared file when rotation loses its liveness
      /// race with recording teardown.
      @concurrent
      private nonisolated func discard(
        writer: any RecordingFileWriter,
        url: URL,
      ) async {
        #if DEBUG
          dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        writer.close()
        try? FileManager().removeItem(at: url)
      }

      @MainActor
      func rotate() async throws(RecordingError) -> URL {
        guard owner.isRecording,
          let (currentURL, configuration, format): (URL, RecordingConfiguration, AVAudioFormat) =
            owner.state.withLock({
              guard let url = $0.recordingURL,
                let configuration = $0.recordingConfiguration,
                let format = configuration.processingFormat
              else {
                return Optional.none
              }
              return Optional((url, configuration, format))
            })
        else {
          throw RecordingError.notRecording
        }

        let sampleRate = Int(format.sampleRate)
        let channelCount = Int(format.channelCount)
        guard sampleRate > 0, channelCount > 0 else {
          throw RecordingError.invalidConfiguration(details: "Invalid processing format")
        }

        let lifecycle = owner.recording
        let (newWriter, newURL) = try await prepareFile(
          configuration: configuration,
          writerBackend: owner.recordingLifecycleState.writerBackend,
        )

        // A stop can begin while file preparation runs off-main. The teardown
        // sentinel becomes authoritative before `isRecording` flips false.
        guard owner.isRecording,
          !owner.engineTearingDown.load(ordering: .sequentiallyConsistent)
        else {
          await discard(writer: newWriter, url: newURL)
          throw RecordingError.notRecording
        }

        let newBuffers = lifecycle.capture.makeAudioBuffers(
          sampleRate: sampleRate,
          channelCount: channelCount,
        )

        if let currentWriter = owner.recordingLifecycleState.writerSession {
          lifecycle.writer.enqueueDrain(for: currentWriter)
        } else {
          owner.state[locked: \.recordingWriter]?.close()
        }

        let snapshot = owner.state { state -> Transferring<TapSnapshot> in
          state.recordingWriter = newWriter
          state.recordingURL = newURL
          state.audioBuffers = newBuffers
          return Transferring(
            TapSnapshot(
              audioBuffers: state.audioBuffers,
              receiverBuffers: state.receiverBuffers,
              receiverTiming: state.receiverTiming,
              converter: state.tapConverter,
              converterInputFormat: state.tapConverterInputFormat,
              converterOutputFormat: state.tapConverterOutputFormat,
              convertedBuffer: state.tapConvertedBuffer,
            ),
          )
        }
        owner.recordingInfrastructure.tapSnapshotLock.withLock { $0 = snapshot.value }

        lifecycle.writer.start(flushing: newBuffers, format: format, to: newWriter)

        let fileFormat = configuration.outputConfiguration.fileFormat.rawValue
        owner.eventSubject.send(
          AudioIOEvent.recordingStarted(url: newURL, format: fileFormat),
        )

        log.info("📼 Rotated recording file to: \(newURL.lastPathComponent, privacy: .public)")
        return currentURL
      }
    }
  }
#endif
