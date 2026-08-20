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
      func rotate() async throws(RecordingError) -> RecordingRotation {
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

        guard format.sampleRate > 0, format.channelCount > 0 else {
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

        // Read before the switch replaces it: it decides whether the completed
        // file has a live writer loop to drain or only a writer to close.
        let completedSession = owner.recordingLifecycleState.writerSession

        // Rotation is a change of *consumer*, not of transport. The tap keeps
        // writing into the same ring buffers across the boundary; only the
        // writer draining them changes, and it changes at an exact frame
        // position rather than by having its input swapped underneath it.
        //
        // Handing the tap fresh rings — which this used to do — cannot be made
        // exact from here. The tap must never block, so it takes its rings
        // under `withLockIfAvailable` and accounts for its frames afterwards;
        // a callback already past that read when the swap happened wrote into
        // the retired ring but advanced the counter past a boundary sampled
        // from it. No amount of locking on this side orders those two events,
        // and the attempts trade the error for a dropped buffer instead.
        // Leaving the tap's rings alone removes the question: there is no
        // moment at which a callback can be on the wrong side of anything.
        //
        // What makes the split exact is the writer loop honouring the target:
        // it reads no further than `boundaryFramePosition`, so the frames past
        // it stay in the ring for the writer that takes over. The two loops
        // share a serial queue, so they can never read it at the same time.
        let switched:
          (boundary: Int64, buffers: [SPSCRingBuffer<Float>], replaced: (any RecordingFileWriter)?)? =
            owner.state { state in
              guard let buffers = state.audioBuffers else { return nil }
              let boundary = owner.recordingSampleTimeAtomic.load(ordering: .relaxed)
              let replaced = state.recordingWriter
              state.recordingWriter = newWriter
              state.recordingURL = newURL
              return (boundary, buffers, replaced)
            }
        guard let switched else {
          await discard(writer: newWriter, url: newURL)
          throw RecordingError.notRecording
        }
        let boundaryFramePosition = switched.boundary

        if let completedSession {
          // Drained to the boundary and no further, so the completed file ends
          // exactly where the new one begins.
          lifecycle.writer.enqueueDrain(
            for: completedSession,
            upTo: boundaryFramePosition,
            logsLiveBuffers: true,
          )
        } else {
          // No writer loop to drain — nothing is queued behind the boundary,
          // so the replaced writer can be closed directly.
          switched.replaced?.close()
        }

        // The new file begins exactly where the completed one ends, reading on
        // from the same rings once the completed writer's loop has stopped.
        lifecycle.writer.start(
          flushing: switched.buffers,
          format: format,
          to: newWriter,
          startingAt: boundaryFramePosition,
        )

        let fileFormat = configuration.outputConfiguration.fileFormat.rawValue
        // Rotation changes the file, never the capture path, so the current
        // resolution carries over; the fallback mirrors the start publish.
        let capture =
          owner.state[locked: \.captureResolution]
          ?? ResolvedCaptureFormat(
            hardware: InputConfiguration(
              sampleRate: SampleRate(format.sampleRate),
              channels: ChannelCount(platform: format.channelCount),
            ),
            processing: InputConfiguration(
              sampleRate: SampleRate(format.sampleRate),
              channels: ChannelCount(platform: format.channelCount),
            ),
          )
        owner.eventSubject.send(
          AudioIOEvent.recordingStarted(url: newURL, format: fileFormat, capture: capture),
        )

        log.info(
          "📼 Rotated recording file to: \(newURL.lastPathComponent, privacy: .public) at frame \(boundaryFramePosition, privacy: .public)",
        )
        return RecordingRotation(
          completedURL: currentURL,
          boundaryFramePosition: boundaryFramePosition,
        )
      }
    }
  }
#endif
