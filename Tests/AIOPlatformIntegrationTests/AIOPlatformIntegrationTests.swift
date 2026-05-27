// © GoodHatsLLC

#if os(iOS)
  import AVFoundation
  import Foundation
  import Testing
  import Tools

  @_spi(TESTING) @testable import AudioIO

  @Suite(.serialized)
  @MainActor
  struct AIOPlatformIntegrationTests {
    @Test
    func routeChangeHandlerExercisesIOSAudioSessionPath() async throws {
      let engine = AIOEngine()
      let configuration = makeRecordingConfiguration(fileFormat: .caf, channelCount: 1)
      let probe = RecordingEventProbe()

      engine.onRecordingInterruption = { interruption in
        probe.record(interruption)
      }
      engine.onRecordingFailed = {
        probe.recordFailure()
      }

      let url = try engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      engine.injectTestAudio(channels: [samples(channelCount: 1, frames: 1_024)[0]])

      let reinstallCalls = LockedCounter()
      let routeFormat = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
      )
      engine.debugInstallSuccessfulTapReinstallOverrideForTesting(tapFormat: routeFormat) {
        reinstallCalls.increment()
      }
      defer { engine.debugClearTapReinstallOverrideForTesting() }

      let session = AVAudioSession.sharedInstance()
      let event = AudioRouteChangeEvent(
        reason: .routeConfigurationChange,
        previousRoute: nil,
        session: session,
      )

      await engine.handleRouteChange(event: event)

      let snapshot = probe.snapshot()
      if session.isInputAvailable {
        #expect(engine.isRecording == true)
        #expect(reinstallCalls.snapshot() == 1)
        #expect(snapshot.failureCount == 0)
        #expect(
          snapshot.interruptions.contains { interruption in
            if case .routeChangeContinuing = interruption {
              return true
            }
            return false
          },
        )
        _ = try await engine.stopRecording()
      } else {
        #expect(engine.isRecording == false)
        #expect(reinstallCalls.snapshot() == 0)
        #expect(snapshot.failureCount == 1)
        #expect(
          snapshot.interruptions.contains { interruption in
            if case .stoppedByInterruption(let reason) = interruption {
              return reason == "No audio input available"
            }
            return false
          },
        )
      }
    }

    @Test
    func interruptionHandlerStopsActiveRecording() async throws {
      let engine = AIOEngine()
      let configuration = makeRecordingConfiguration(fileFormat: .caf, channelCount: 1)
      let probe = RecordingEventProbe()

      engine.onRecordingInterruption = { interruption in
        probe.record(interruption)
      }
      engine.onRecordingFailed = {
        probe.recordFailure()
      }

      let url = try engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      engine.injectTestAudio(channels: [samples(channelCount: 1, frames: 1_024)[0]])
      await engine.handleInterruption(type: .began, options: nil)

      let stopped = await waitUntil(timeout: .seconds(2)) {
        engine.isRecording == false
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
    }

    @Test
    func publicSegmentPlaybackScrubStaysSegmentRelative() async throws {
      let fixture = try AudioFixture(duration: 3, sampleRate: 48_000)
      defer { fixture.cleanup() }
      let engine = AIOEngine()

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
    func declaredChannelMatrixStartsAndStopsTestRecordings() async throws {
      for testCase in declaredChannelMatrixCases() {
        let engine = AIOEngine()
        let configuration = makeRecordingConfiguration(
          fileFormat: testCase.fileFormat,
          channelCount: testCase.channelCount,
        )

        let url = try engine.startTestRecording(
          configuration: configuration,
          enableReceivers: false,
        )
        defer { try? FileManager.default.removeItem(at: url) }

        engine.injectTestAudio(
          channels: samples(channelCount: testCase.channelCount, frames: 1_024),
        )
        let stoppedURL = try await engine.stopRecording()

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
        let engine = AIOEngine()
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

        let firstURL = try engine.startTestRecording(
          configuration: configuration,
          enableReceivers: false,
        )

        engine.injectTestAudio(
          channels: samples(channelCount: testCase.channelCount, frames: 2_048),
        )

        let rotatedURL = try await engine.rotateRecordingFile()
        #expect(rotatedURL == firstURL)

        let drainCompleted = await waitUntil(timeout: .seconds(3)) {
          engine.debugDrainingWriterSessionIDsForTesting().isEmpty
            && fileHasBytes(at: rotatedURL)
        }
        #expect(drainCompleted == true)

        let nextURL = try #require(engine.debugCurrentRecordingURL())
        #expect(nextURL != firstURL)

        engine.injectTestAudio(
          channels: samples(channelCount: testCase.channelCount, frames: 2_048),
        )
        let finalURL = try await engine.stopRecording()

        #expect(finalURL == nextURL)
        #expect(fileHasBytes(at: finalURL) == true)

        if supportsAVAudioFileReadback(testCase.fileFormat) {
          let rotatedFile = try AVAudioFile(forReading: rotatedURL)
          let finalFile = try AVAudioFile(forReading: finalURL)
          #expect(rotatedFile.fileFormat.channelCount == AVAudioChannelCount(testCase.channelCount))
          #expect(finalFile.fileFormat.channelCount == AVAudioChannelCount(testCase.channelCount))
          #expect(rotatedFile.length > 0)
          #expect(finalFile.length > 0)
        }
      }
    }

    @Test
    func unsupportedChannelCountFailsBeforeRecordingSetup() throws {
      let engine = AIOEngine()
      let configuration = makeRecordingConfiguration(fileFormat: .caf, channelCount: 33)

      do {
        _ = try engine.startTestRecording(configuration: configuration, enableReceivers: false)
        Issue.record("Expected unsupportedRecordingChannelCount")
      } catch RecordingError.unsupportedChannelCount(let requested, let maximum) {
        #expect(requested == 33)
        #expect(maximum == 32)
      } catch {
        Issue.record("Expected unsupportedRecordingChannelCount, got \(error)")
      }

      #expect(engine.isRecording == false)
      #expect(engine.debugCurrentRecordingURL() == nil)
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
