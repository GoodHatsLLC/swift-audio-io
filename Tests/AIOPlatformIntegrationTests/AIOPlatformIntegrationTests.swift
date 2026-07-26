// © GoodHatsLLC

#if os(iOS)
  import AIOTestSupport
  import AVFoundation
  import Foundation
  import Testing
  import Tools
  @testable import AudioIO

  @Suite(.serialized)
  @MainActor
  struct AIOPlatformIntegrationTests {
    @Test
    func routeChangeHandlerExercisesIOSAudioSessionPath() async throws {
      let routeFormat = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
      )
      let (engine, backend, tapInstaller) = AIOEngine.fakeRecording(
        tapInstaller: FakeTapInstaller(tapFormat: routeFormat),
      )
      let configuration = makeRecordingConfiguration(fileFormat: .caf, channelCount: 1)
      let probe = RecordingEventProbe()
      let bridge = probe.bridge(to: engine)
      defer { bridge.cancelNow() }

      let url = try await engine.startRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      backend.inject(channels: [samples(channelCount: 1, frames: 1_024)[0]])
      let installsAfterStart = tapInstaller.installCount()

      let session = AVAudioSession.sharedInstance()
      let event = AudioRouteChange(
        reason: .configurationChanged,
        previousRoute: nil,
        currentRoute: AudioRouteSnapshot(
          inputs: session.currentRoute.inputs.map {
            AudioPortSnapshot(
              name: $0.portName,
              uid: $0.uid,
              type: $0.portType.rawValue,
              channelCount: $0.channels?.count ?? 0,
            )
          },
          outputs: session.currentRoute.outputs.map {
            AudioPortSnapshot(
              name: $0.portName,
              uid: $0.uid,
              type: $0.portType.rawValue,
              channelCount: $0.channels?.count ?? 0,
            )
          },
        ),
        session: AudioSessionSnapshot(
          category: session.category.rawValue,
          mode: session.mode.rawValue,
          options: [],
          sampleRate: session.sampleRate,
          ioBufferDuration: session.ioBufferDuration,
          inputNumberOfChannels: session.inputNumberOfChannels,
          isInputAvailable: session.isInputAvailable,
        ),
      )

      await engine.handleAudioSystemEvent(.routeChanged(event))

      if session.isInputAvailable {
        let captured = await waitUntil(timeout: .seconds(2)) {
          probe.snapshot().interruptions.contains { interruption in
            if case .routeChangeContinuing = interruption { return true }
            return false
          }
        }
        #expect(captured == true)

        let snapshot = probe.snapshot()
        #expect(engine.isRecording == true)
        #expect(tapInstaller.installCount() == installsAfterStart + 1)
        #expect(snapshot.failureCount == 0)
        _ = try await engine.stopRecording()
      } else {
        let captured = await waitUntil(timeout: .seconds(2)) {
          let snapshot = probe.snapshot()
          return snapshot.failureCount >= 1
            && snapshot.interruptions.contains { interruption in
              if case .stoppedByInterruption(let reason) = interruption {
                return reason == "No audio input available"
              }
              return false
            }
        }
        #expect(captured == true)

        #expect(engine.isRecording == false)
        #expect(tapInstaller.installCount() == installsAfterStart)
      }
      await bridge.cancel()
    }

    @Test
    func interruptionHandlerStopsActiveRecording() async throws {
      let (engine, backend, _) = AIOEngine.fakeRecording()
      let configuration = makeRecordingConfiguration(fileFormat: .caf, channelCount: 1)
      let probe = RecordingEventProbe()
      let bridge = probe.bridge(to: engine)
      defer { bridge.cancelNow() }

      let url = try await engine.startRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      backend.inject(channels: [samples(channelCount: 1, frames: 1_024)[0]])
      await engine.handleAudioSystemEvent(.interruptionBegan)

      let stopped = await waitUntil(timeout: .seconds(2)) {
        engine.isRecording == false && probe.snapshot().failureCount == 1
      }
      #expect(stopped == true)

      let snapshot = probe.snapshot()
      #expect(snapshot.failureCount == 1)
      #expect(
        snapshot.interruptions.contains { interruption in
          if case .stoppedByInterruption(let reason) = interruption {
            return reason == "Audio session interrupted"
          }
          return false
        },
      )
      #expect(fileHasBytes(at: url) == true)
      await bridge.cancel()
    }

    @Test
    func publicSegmentPlaybackScrubStaysSegmentRelative() async throws {
      let fixture = try AudioFixture(duration: 3, sampleRate: 48_000)
      defer { fixture.cleanup() }
      let (engine, _, _) = AIOEngine.fakeRecording()

      let initial = try await engine.playSegment(
        url: fixture.url,
        startTime: 1,
        endTime: 2,
        playbackPollingInterval: .seconds(60),
      )
      #expect(abs(initial.duration - 1) < 0.001)
      #expect(abs((initial.time ?? 0)) < 0.05)

      let scrubbed = try #require(try engine.scrub(to: 0.25, updatePlaybackPolling: false))
      #expect(abs((scrubbed.time ?? -1) - 0.25) < 0.001)
      #expect(abs(scrubbed.duration - 1) < 0.001)

      let nearEnd = try #require(try engine.scrub(to: 1, updatePlaybackPolling: false))
      let expectedUpperBound = Double(fixture.frames(seconds: 1) - 1) / fixture.sampleRate
      #expect(abs((nearEnd.time ?? -1) - expectedUpperBound) < 0.001)
      #expect(abs(nearEnd.duration - 1) < 0.001)

      await engine.stopPlayback()
    }

    @Test
    func audioSystemInterruptionResumesPlaybackThroughPublicHandler() async throws {
      let fixture = try AudioFixture(duration: 3, sampleRate: 48_000)
      defer { fixture.cleanup() }
      let (engine, _, _) = AIOEngine.fakeRecording()

      _ = try await engine.play(
        url: fixture.url,
        playbackPollingInterval: .seconds(60),
      )
      #expect(engine.isPlayback)

      await engine.handleAudioSystemEvent(.interruptionBegan)
      #expect(engine.isPlayback == false)

      await engine.handleAudioSystemEvent(.interruptionEnded(shouldResume: true))
      #expect(engine.isPlayback)
      #expect(engine.playback?.file == fixture.url)

      await engine.stopPlayback()
    }

    @Test
    func declaredChannelMatrixStartsAndStopsTestRecordings() async throws {
      for testCase in declaredChannelMatrixCases() {
        let (engine, backend, _) = AIOEngine.fakeRecording()
        let configuration = makeRecordingConfiguration(
          fileFormat: testCase.fileFormat,
          channelCount: testCase.channelCount,
        )

        let url = try await engine.startRecording(
          configuration: configuration,
        )
        defer { try? FileManager.default.removeItem(at: url) }

        backend.inject(
          channels: samples(channelCount: testCase.channelCount, frames: 1_024),
        )
        let stoppedURL = try await engine.stopRecording().completedURL

        #expect(stoppedURL == url)
        #expect(fileHasBytes(at: url) == true)

        if supportsAVAudioFileReadback(testCase.fileFormat) {
          let file = try AVAudioFile(forReading: url)
          #expect(file.fileFormat.channelCount == AVAudioChannelCount(testCase.channelCount))
          #expect(file.length > 0)
        }
      }
    }

    @Test
    func writerDrainAndRotationCoversDeclaredFormatEdges() async throws {
      for testCase in declaredFormatEdgeCases() {
        let (engine, backend, _) = AIOEngine.fakeRecording()
        let outputDirectory = FileManager.default.temporaryDirectory
          .appendingPathComponent(
            "AIOPlatformIntegration-\(testCase.fileFormat.rawValue)-\(UUID().uuidString)",
            isDirectory: true,
          )
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let configuration = makeRecordingConfiguration(
          fileFormat: testCase.fileFormat,
          channelCount: testCase.channelCount,
          outputDestination: .directory(outputDirectory),
        )

        let firstURL = try await engine.startRecording(
          configuration: configuration,
        )

        backend.inject(
          channels: samples(channelCount: testCase.channelCount, frames: 2_048),
        )

        let rotation = try await engine.rotateRecordingFile()
        let rotatedURL = rotation.completedURL
        #expect(rotatedURL == firstURL)

        let drainCompleted = await waitUntil(timeout: .seconds(3)) {
          engine.drainingWriterSessionIDs().isEmpty
            && fileHasBytes(at: rotatedURL)
        }
        #expect(drainCompleted == true)

        let nextURL = try #require(engine.currentRecordingURL())
        #expect(nextURL != firstURL)

        backend.inject(
          channels: samples(channelCount: testCase.channelCount, frames: 2_048),
        )
        let completion = try await engine.stopRecording()
        let finalURL = completion.completedURL

        #expect(finalURL == nextURL)
        #expect(fileHasBytes(at: finalURL) == true)

        // Every format splits at the same place: the boundary is a fact about
        // the capture stream, not about the encoder.
        #expect(rotation.boundaryFramePosition == 2_048)
        #expect(completion.boundaryFramePosition == 4_096)

        if supportsAVAudioFileReadback(testCase.fileFormat) {
          let rotatedFile = try AVAudioFile(forReading: rotatedURL)
          let finalFile = try AVAudioFile(forReading: finalURL)
          #expect(rotatedFile.fileFormat.channelCount == AVAudioChannelCount(testCase.channelCount))
          #expect(finalFile.fileFormat.channelCount == AVAudioChannelCount(testCase.channelCount))
          #expect(rotatedFile.length > 0)
          #expect(finalFile.length > 0)

          // What the boundary means on disk is format-dependent, and that is
          // exactly what `preservesExactFrameCount` reports: for the PCM
          // containers and FLAC each file holds precisely the frames between
          // adjacent boundaries; AAC priming and tail padding make the encoded
          // formats longer than the PCM they were handed.
          if testCase.fileFormat.preservesExactFrameCount {
            #expect(rotatedFile.length == rotation.boundaryFramePosition)
            #expect(
              finalFile.length
                == completion.boundaryFramePosition - rotation.boundaryFramePosition,
            )
          } else {
            #expect(rotatedFile.length >= rotation.boundaryFramePosition)
          }
        }
      }
    }

    @Test
    func unsupportedChannelCountFailsBeforeRecordingSetup() async throws {
      let (engine, _, _) = AIOEngine.fakeRecording()
      let configuration = makeRecordingConfiguration(fileFormat: .caf, channelCount: 33)

      do {
        _ = try await engine.startRecording(configuration: configuration)
        Issue.record("Expected unsupportedChannelCount")
      } catch RecordingError.unsupportedChannelCount(let requested, let maximum) {
        #expect(requested == 33)
        #expect(maximum == 32)
      } catch {
        Issue.record("Expected unsupportedChannelCount, got \(error)")
      }

      #expect(engine.isRecording == false)
      #expect(engine.currentRecordingURL() == nil)
    }

    private func declaredChannelMatrixCases() -> [RecordingMatrixCase] {
      [
        .init(fileFormat: .aac, channelCount: 1),
        .init(fileFormat: .aac, channelCount: 2),
        .init(fileFormat: .aac, channelCount: 8),
        .init(fileFormat: .adts, channelCount: 1),
        .init(fileFormat: .adts, channelCount: 2),
        .init(fileFormat: .adts, channelCount: 8),
        .init(fileFormat: .flac, channelCount: 1),
        .init(fileFormat: .flac, channelCount: 2),
        .init(fileFormat: .flac, channelCount: 4),
        .init(fileFormat: .flac, channelCount: 8),
        .init(fileFormat: .caf, channelCount: 1),
        .init(fileFormat: .caf, channelCount: 2),
        .init(fileFormat: .caf, channelCount: 4),
        .init(fileFormat: .caf, channelCount: 32),
        .init(fileFormat: .wav, channelCount: 1),
        .init(fileFormat: .wav, channelCount: 2),
        .init(fileFormat: .wav, channelCount: 4),
        .init(fileFormat: .wav, channelCount: 32),
        .init(fileFormat: .aiff, channelCount: 1),
        .init(fileFormat: .aiff, channelCount: 2),
        .init(fileFormat: .aiff, channelCount: 4),
        .init(fileFormat: .aiff, channelCount: 32),
      ]
    }

    private func declaredFormatEdgeCases() -> [RecordingMatrixCase] {
      [
        .init(fileFormat: .aac, channelCount: 8),
        .init(fileFormat: .adts, channelCount: 8),
        .init(fileFormat: .flac, channelCount: 8),
        .init(fileFormat: .caf, channelCount: 32),
        .init(fileFormat: .wav, channelCount: 32),
        .init(fileFormat: .aiff, channelCount: 32),
      ]
    }

    private func makeRecordingConfiguration(
      fileFormat: FileFormat,
      channelCount: Int,
      outputDestination: RecordingConfiguration.OutputDestination = .temporary,
    ) -> RecordingConfiguration {
      RecordingConfiguration(
        inputConfiguration: InputConfiguration(
          sampleRate: .dvd,
          channels: .init(platform: AVAudioChannelCount(channelCount)),
        ),
        outputConfiguration: OutputConfiguration(
          fileFormat: fileFormat,
          bitDepth: bitDepth(for: fileFormat),
          quality: .high,
        ),
        outputDestination: outputDestination,
      )
    }

    private func bitDepth(for fileFormat: FileFormat) -> BitDepth {
      switch fileFormat {
      case .flac:
        .pcmInt24
      case .aiff:
        .pcmInt16
      case .aac, .adts, .caf, .wav:
        .pcmFloat32
      }
    }

    private func supportsAVAudioFileReadback(_ fileFormat: FileFormat) -> Bool {
      switch fileFormat {
      case .aiff, .caf, .wav:
        true
      case .aac, .adts, .flac:
        false
      }
    }

    private func samples(channelCount: Int, frames: Int) -> [[Float]] {
      (0..<channelCount).map { channel in
        (0..<frames).map { frame in
          Float(channel + 1) / 100 + Float(frame) / 1_000_000
        }
      }
    }

    private func waitUntil(
      timeout: Duration,
      condition: @escaping @MainActor @Sendable () async -> Bool,
    ) async -> Bool {
      let clock = ContinuousClock()
      let polling = PollingPolicy(interval: .milliseconds(10))
      let deadline = clock.now.advanced(by: timeout)
      while clock.now < deadline {
        if await condition() { return true }
        try? await polling.waitForNextPoll()
      }
      return await condition()
    }

    private func fileHasBytes(at url: URL) -> Bool {
      guard FileManager.default.fileExists(atPath: url.path) else { return false }
      do {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return (values.fileSize ?? 0) > 0
      } catch {
        return false
      }
    }
  }

  private struct RecordingMatrixCase: CustomStringConvertible {
    let fileFormat: FileFormat
    let channelCount: Int

    var description: String {
      "\(fileFormat.description) \(channelCount)ch"
    }
  }

  private struct AudioFixture {
    let url: URL
    let sampleRate: Double

    init(duration: TimeInterval, sampleRate: Double) throws {
      self.sampleRate = sampleRate
      self.url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIOPlatformSegment-\(UUID().uuidString).caf")
      let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
      )
      let writer = try AVAudioFile(forWriting: url, settings: format.settings)
      let frameCount = AVAudioFrameCount(duration * sampleRate)
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
      buffer.frameLength = frameCount
      try writer.write(from: buffer)
    }

    func frames(seconds: TimeInterval) -> AVAudioFramePosition {
      AVAudioFramePosition(seconds * sampleRate)
    }

    func cleanup() {
      try? FileManager.default.removeItem(at: url)
    }
  }

  // SAFETY: All mutable state is protected by NSLock, only accessed under lock.
  private final class RecordingEventProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var interruptions: [AIOEngine.RecordingInterruption] = []
    private var failureCount = 0

    func record(_ interruption: AIOEngine.RecordingInterruption) {
      lock.lock()
      interruptions.append(interruption)
      lock.unlock()
    }

    func recordFailure() {
      lock.lock()
      failureCount += 1
      lock.unlock()
    }

    func snapshot() -> (interruptions: [AIOEngine.RecordingInterruption], failureCount: Int) {
      lock.lock()
      defer { lock.unlock() }
      return (interruptions, failureCount)
    }

    /// Subscribes to `engine.events` before returning and owns the subscription
    /// behind the cancellable work handle.
    @MainActor
    func bridge(to engine: AIOEngine) -> RecordingEventBridge {
      let subscription = engine.events.subscribe()
      let probe = self
      let work = MainActorOwnedWork {
        for await event in subscription.events {
          switch event {
          case .recordingInterruption(let interruption):
            probe.record(interruption)
          case .recordingFailed:
            probe.recordFailure()
          default:
            break
          }
        }
      }
      return RecordingEventBridge(subscription: subscription, work: work)
    }
  }

  private struct RecordingEventBridge: Sendable {
    let subscription: AsyncBroadcaster<AudioIOEvent>.Subscription
    let work: MainActorOwnedWork

    func cancelNow() {
      subscription.cancel()
      work.cancelNow()
    }

    func cancel() async {
      subscription.cancel()
      await work.cancel()
    }
  }

  // SAFETY: All mutable state is protected by NSLock, only accessed under lock.
  private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
      lock.lock()
      value += 1
      lock.unlock()
    }

    func snapshot() -> Int {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }
#endif
