// © GoodHatsLLC

#if canImport(AVFoundation)
  import AVFoundation
  import Foundation
  import Testing

  @testable import AudioIO

  @MainActor
  struct PlaybackRuntimeSegmentTests {
    private let sampleRate = 48_000.0

    @Test
    func `segment playback reports segment-relative time and duration`() throws {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      let engine = AIOEngine()
      let segment = PlaybackSegment(
        startFrame: fixture.frames(seconds: 1),
        frameCount: AVAudioFrameCount(fixture.frames(seconds: 2)),
      )
      let instance = PlaybackInstance(
        id: .init(),
        file: fixture.file,
        startFrame: segment.startFrame + fixture.frames(seconds: 0.5),
        pollingInterval: .seconds(0.5),
        activeSegment: segment,
      )

      let playback = engine.getPlayback(for: instance)

      #expect(playback.time == 0.5)
      #expect(playback.duration == 2)
    }

    @Test
    func `scrub inside segment preserves segment range and completion callback`() throws {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      let engine = AIOEngine()
      let segment = PlaybackSegment(
        startFrame: fixture.frames(seconds: 1),
        frameCount: AVAudioFrameCount(fixture.frames(seconds: 2)),
      )
      let onComplete: @MainActor @Sendable () -> Void = {}
      engine.playbackState[locked: \.playbackInstance] = PlaybackInstance(
        id: .init(),
        file: fixture.file,
        startFrame: segment.startFrame,
        pollingInterval: .seconds(0.5),
        activeSegment: segment,
        onComplete: onComplete,
      )

      let playback = try #require(try engine.scrub(to: 0.75, updatePlaybackPolling: false))
      let updated = try #require(engine.playbackState[locked: \.playbackInstance])
      engine.scrubTask = nil

      let expectedFrame = segment.startFrame + fixture.frames(seconds: 0.75)
      #expect(updated.startFrame == expectedFrame)
      #expect(updated.activeSegment == segment)
      #expect(updated.onComplete != nil)
      #expect(updated.scheduledFrameCount == AVAudioFrameCount(segment.endFrame - expectedFrame))
      #expect(playback.time == 0.75)
      #expect(playback.duration == 2)
    }

    @Test
    func `segment scheduling completes at segment end`() throws {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      let segment = PlaybackSegment(
        startFrame: fixture.frames(seconds: 1),
        frameCount: AVAudioFrameCount(fixture.frames(seconds: 2)),
      )
      let onComplete: @MainActor @Sendable () -> Void = {}
      let instance = PlaybackInstance(
        id: .init(),
        file: fixture.file,
        startFrame: segment.startFrame,
        pollingInterval: .seconds(0.5),
        activeSegment: segment,
        onComplete: onComplete,
      )

      #expect(instance.scheduledFrameCount == segment.frameCount)
      #expect(instance.onComplete != nil)
    }

    @Test
    func `segment scrub clamps exact end to half-open upper bound`() throws {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      let engine = AIOEngine()
      let segment = PlaybackSegment(
        startFrame: fixture.frames(seconds: 1),
        frameCount: AVAudioFrameCount(fixture.frames(seconds: 2)),
      )
      engine.playbackState[locked: \.playbackInstance] = PlaybackInstance(
        id: .init(),
        file: fixture.file,
        startFrame: segment.startFrame,
        pollingInterval: .seconds(0.5),
        activeSegment: segment,
      )

      let playback = try #require(try engine.scrub(to: 2, updatePlaybackPolling: false))
      let updated = try #require(engine.playbackState[locked: \.playbackInstance])
      engine.scrubTask = nil

      let expectedFrame = segment.endFrame - 1
      #expect(updated.startFrame == expectedFrame)
      #expect(updated.scheduledFrameCount == 1)
      #expect(playback.time == Double(segment.frameCount - 1) / sampleRate)
      #expect(playback.duration == 2)
    }

    @Test
    func `segment scrub reschedules only remaining segment frames`() throws {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      let engine = AIOEngine()
      let segment = PlaybackSegment(
        startFrame: fixture.frames(seconds: 1),
        frameCount: AVAudioFrameCount(fixture.frames(seconds: 2)),
      )
      engine.playbackState[locked: \.playbackInstance] = PlaybackInstance(
        id: .init(),
        file: fixture.file,
        startFrame: segment.startFrame,
        pollingInterval: .seconds(0.5),
        activeSegment: segment,
      )

      _ = try engine.scrub(to: 1.25, updatePlaybackPolling: false)
      let updated = try #require(engine.playbackState[locked: \.playbackInstance])
      engine.scrubTask = nil

      let expectedFrame = segment.startFrame + fixture.frames(seconds: 1.25)
      #expect(updated.startFrame == expectedFrame)
      #expect(updated.scheduledFrameCount == AVAudioFrameCount(segment.endFrame - expectedFrame))
    }

    @Test
    func `whole-file scrub remains file-relative`() throws {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      let engine = AIOEngine()
      engine.playbackState[locked: \.playbackInstance] = PlaybackInstance(
        id: .init(),
        file: fixture.file,
        startFrame: 0,
        pollingInterval: .seconds(0.5),
      )

      let playback = try #require(try engine.scrub(to: 1.5, updatePlaybackPolling: false))
      let updated = try #require(engine.playbackState[locked: \.playbackInstance])
      engine.scrubTask = nil

      let expectedFrame = fixture.frames(seconds: 1.5)
      #expect(updated.activeSegment == nil)
      #expect(updated.startFrame == expectedFrame)
      #expect(updated.scheduledFrameCount == AVAudioFrameCount(fixture.file.length - expectedFrame))
      #expect(playback.time == 1.5)
      #expect(playback.duration == 4)

      do {
        _ = try engine.scrub(to: 4, updatePlaybackPolling: false)
        Issue.record("Expected whole-file scrub at exact duration to fail")
      } catch PlaybackError.invalidScrubTime(let value) {
        #expect(value == 4)
      } catch {
        Issue.record("Expected invalidScrubTime, got \(error)")
      }
    }

    @Test
    func `scrub mode controls playback polling updates`() throws {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      let engine = AIOEngine()
      engine.playbackState[locked: \.playbackInstance] = PlaybackInstance(
        id: .init(),
        file: fixture.file,
        startFrame: 0,
        pollingInterval: .seconds(10),
      )
      defer {
        engine.playbackTask = nil
        engine.scrubTask = nil
      }

      _ = try engine.scrub(to: 0.5, mode: .interactive)

      #expect(engine.playbackTask == nil)
      engine.scrubTask = nil

      _ = try engine.scrub(to: 1.0, mode: .committed)

      #expect(engine.playbackTask != nil)
    }

    @Test
    func `paused playback reports the last observed time, not the start frame`() throws {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      let engine = AIOEngine()
      let instance = PlaybackInstance(
        id: .init(),
        file: fixture.file,
        startFrame: 0,
        pollingInterval: .seconds(0.5),
      )
      engine.playbackState[locked: \.playbackInstance] = instance
      engine.playbackState[locked: \.lastObservedPlaybackTime] = ObservedPlaybackTime(
        instanceID: instance.id,
        time: 1.5,
      )

      // The player never rendered, so `getPlayback` takes its node-less
      // fallback path — the same path a paused node hits.
      let playback = engine.getPlayback(for: instance)

      #expect(playback.time == 1.5)
    }

    @Test
    func `paused fallback ignores an observed time from a different instance`() throws {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      let engine = AIOEngine()
      let instance = PlaybackInstance(
        id: .init(),
        file: fixture.file,
        startFrame: fixture.frames(seconds: 0.75),
        pollingInterval: .seconds(0.5),
      )
      engine.playbackState[locked: \.playbackInstance] = instance
      engine.playbackState[locked: \.lastObservedPlaybackTime] = ObservedPlaybackTime(
        instanceID: .init(),
        time: 1.5,
      )

      let playback = engine.getPlayback(for: instance)

      #expect(playback.time == 0.75)
    }

    @Test
    func `begin jog inside segment reports segment-relative time and duration`() throws {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      let engine = AIOEngine()
      let segment = PlaybackSegment(
        startFrame: fixture.frames(seconds: 1),
        frameCount: AVAudioFrameCount(fixture.frames(seconds: 2)),
      )
      installPlayback(on: engine, fixture: fixture, startFrame: segment.startFrame, segment: segment)
      defer { clearJog(on: engine) }

      let snapshot = try #require(try engine.beginPlaybackJog(at: 0.75))
      engine.jogPreparationTask = nil
      engine.jogPollingTask = nil
      let jogInstance = try #require(engine.playbackState[locked: \.playbackJogInstance])

      #expect(snapshot.time == 0.75)
      #expect(snapshot.duration == 2)
      #expect(snapshot.rate == 0)
      #expect(jogInstance.currentCursorFrame == Double(segment.startFrame + fixture.frames(seconds: 0.75)))
    }

    @Test
    func `update jog applies clamped rate and segment-relative anchor`() throws {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      let engine = AIOEngine()
      let segment = PlaybackSegment(
        startFrame: fixture.frames(seconds: 1),
        frameCount: AVAudioFrameCount(fixture.frames(seconds: 2)),
      )
      installPlayback(on: engine, fixture: fixture, startFrame: segment.startFrame, segment: segment)
      defer { clearJog(on: engine) }
      _ = try engine.beginPlaybackJog(at: 0.5)
      engine.jogPreparationTask = nil
      engine.jogPollingTask = nil

      let snapshot = try #require(
        try engine.updatePlaybackJog(rate: PlaybackJogRate(-8), anchorTime: 1.25),
      )
      let jogInstance = try #require(engine.playbackState[locked: \.playbackJogInstance])

      #expect(snapshot.rate == -4)
      #expect(snapshot.time == 1.25)
      #expect(jogInstance.currentCursorFrame == Double(segment.startFrame + fixture.frames(seconds: 1.25)))
    }

    @Test
    func `ending committed jog seeks through normal playback instance`() throws {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      let engine = AIOEngine()
      installPlayback(on: engine, fixture: fixture, startFrame: 0)
      defer {
        engine.scrubTask = nil
        clearJog(on: engine)
      }
      _ = try engine.beginPlaybackJog(at: 0.5)
      engine.jogPreparationTask = nil
      engine.jogPollingTask = nil
      _ = try engine.updatePlaybackJog(rate: .paused, anchorTime: 1.5)

      let playback = try #require(try engine.endPlaybackJog(commit: true))
      let updated = try #require(engine.playbackState[locked: \.playbackInstance])
      engine.scrubTask = nil

      #expect(playback.time == 1.5)
      #expect(updated.startFrame == fixture.frames(seconds: 1.5))
      #expect(engine.playbackState[locked: \.playbackJogInstance] == nil)
    }

    @Test
    func `ending reverted jog restores pre-jog time`() throws {
      let fixture = try makeFixture()
      defer { fixture.cleanup() }
      let engine = AIOEngine()
      installPlayback(on: engine, fixture: fixture, startFrame: fixture.frames(seconds: 0.75))
      defer {
        engine.scrubTask = nil
        clearJog(on: engine)
      }
      _ = try engine.beginPlaybackJog(at: 0.75)
      engine.jogPreparationTask = nil
      engine.jogPollingTask = nil
      _ = try engine.updatePlaybackJog(rate: PlaybackJogRate.normalForward, anchorTime: 1.75)

      let playback = try #require(try engine.endPlaybackJog(commit: false))
      let updated = try #require(engine.playbackState[locked: \.playbackInstance])
      engine.scrubTask = nil

      #expect(playback.time == 0.75)
      #expect(updated.startFrame == fixture.frames(seconds: 0.75))
      #expect(engine.playbackState[locked: \.playbackJogInstance] == nil)
    }

    @Test
    func `jog render state advances cursor forward and backward`() throws {
      let store = PlaybackJogPCMStore(
        baseFrame: 0,
        channels: [Array(repeating: 0.25, count: 64)],
      )
      let forward = PlaybackJogRenderState(
        cursorFrame: 8,
        rate: 1,
        lowerBoundFrame: 0,
        upperBoundFrame: 64,
        sourceSampleRate: sampleRate,
        channels: 1,
        pcm: store,
      )
      let reverse = PlaybackJogRenderState(
        cursorFrame: 32,
        rate: -1,
        lowerBoundFrame: 0,
        upperBoundFrame: 64,
        sourceSampleRate: sampleRate,
        channels: 1,
        pcm: store,
      )
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
      let forwardBuffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
      let reverseBuffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))

      #expect(
        unsafe forward.render(
          frameCount: 8,
          outputData: forwardBuffer.mutableAudioBufferList,
        ) == noErr,
      )
      #expect(
        unsafe reverse.render(
          frameCount: 8,
          outputData: reverseBuffer.mutableAudioBufferList,
        ) == noErr,
      )

      #expect(forward.cursorFrame == 16)
      #expect(reverse.cursorFrame == 24)
    }

    private func makeFixture() throws -> AudioFixture {
      try AudioFixture(duration: 4, sampleRate: sampleRate)
    }

    private func installPlayback(
      on engine: AIOEngine,
      fixture: AudioFixture,
      startFrame: AVAudioFramePosition,
      segment: PlaybackSegment? = nil,
    ) {
      engine.playbackState[locked: \.playbackInstance] = PlaybackInstance(
        id: .init(),
        file: fixture.file,
        startFrame: startFrame,
        pollingInterval: .seconds(0.5),
        activeSegment: segment,
      )
    }

    private func clearJog(on engine: AIOEngine) {
      engine.jogPreparationTask = nil
      engine.jogPollingTask = nil
      engine.playbackState[locked: \.playbackJogInstance] = nil
      engine.setPlaybackJog(nil)
    }
  }

  private struct AudioFixture {
    let url: URL
    let file: AVAudioFile
    let sampleRate: Double

    init(duration: TimeInterval, sampleRate: Double) throws {
      self.sampleRate = sampleRate
      self.url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PlaybackRuntimeSegmentTests-\(UUID().uuidString).caf")
      let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
      )
      let writer = try AVAudioFile(forWriting: url, settings: format.settings)
      let frameCount = AVAudioFrameCount(duration * sampleRate)
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
      buffer.frameLength = frameCount
      try writer.write(from: buffer)
      self.file = try AVAudioFile(forReading: url)
    }

    func frames(seconds: TimeInterval) -> AVAudioFramePosition {
      AVAudioFramePosition(seconds * sampleRate)
    }

    func cleanup() {
      try? FileManager.default.removeItem(at: url)
    }
  }
#endif
