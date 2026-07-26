// © GoodHatsLLC

#if canImport(AVFoundation)
  @testable import AIOEngineCore
  import AIOTestSupport
  import Atomics
  import AVFoundation
  import Foundation
  import Testing
  import Tools
  @testable import AIOAudioSession
  @testable import AudioIO

  /// Boundary reporting for a rotated capture.
  ///
  /// Rotation is already sample-continuous — the tap keeps running while the
  /// old writer drains — so a consumer can treat the files as one recording
  /// *if* it knows where each one ends. These tests pin the three properties
  /// that make that possible: the reported boundaries are strictly increasing
  /// and close on the capture total, each boundary difference is the file's
  /// real frame count, and no frame is dropped or duplicated across a split.
  ///
  /// Asserting only "two non-empty files exist" cannot see any of that: a
  /// boundary that is off by a buffer produces exactly the same two files.
  @Suite(.serialized)
  struct RecordingRotationBoundaryTests {
    @Test
    func `boundaries increase and close on the capture total`() async throws {
      let capture = try await record(segments: [ramp(1_024), ramp(2_048), ramp(512)])
      defer { try? FileManager.default.removeItem(at: capture.directory) }

      #expect(capture.boundaries == [1_024, 3_072, 3_584])
      #expect(
        zip(capture.boundaries, capture.boundaries.dropFirst()).allSatisfy { $0 < $1 },
        "boundaries must be strictly increasing so segment lengths are positive",
      )

      // The final boundary closes the arithmetic: it is the whole capture, so a
      // consumer can assert its assembled segments sum to it.
      let total = capture.segmentLengths.reduce(0, +)
      #expect(capture.boundaries.last == total)

      // And it agrees with the cumulative capture counter, which — as
      // `RecordingTimingSnapshot.capturedFrameCount` now documents — is *not*
      // reset by a rotation.
      let snapshot = try #require(await MainActor.run { capture.engine.recordingTimingSnapshot() })
      #expect(Int64(snapshot.capturedFrameCount) == capture.boundaries.last)
    }

    @Test
    func `each boundary difference is the file's decoded frame count`() async throws {
      let capture = try await record(segments: [ramp(1_024), ramp(2_048), ramp(512)])
      defer { try? FileManager.default.removeItem(at: capture.directory) }

      let decodedLengths = try capture.urls.map { try AVAudioFile(forReading: $0).length }
      #expect(decodedLengths == capture.segmentLengths)
    }

    @Test
    func `concatenated rotations reproduce the injected signal`() async throws {
      // A full-scale sine makes a placement error visible: a dropped or
      // duplicated frame is a phase step, and a misreported boundary puts the
      // step at a known index.
      let sampleRate = Double(SampleRate.dvd.hz)
      let frequency = 440.0
      let source = sine(frameCount: 3_600, frequency: frequency, sampleRate: sampleRate)
      let segments = [
        Array(source[0..<1_200]),
        Array(source[1_200..<2_400]),
        Array(source[2_400..<3_600]),
      ]

      let capture = try await record(segments: segments)
      defer { try? FileManager.default.removeItem(at: capture.directory) }

      #expect(capture.boundaries == [1_200, 2_400, 3_600])

      let assembled = try capture.urls.flatMap { try readSamples(at: $0) }
      try #require(assembled.count == source.count)
      let worstError = zip(assembled, source).map { abs($0 - $1) }.max() ?? 0
      #expect(worstError < 1e-6, "concatenated rotations must be sample-identical to the input")

      // Phase continuity, stated independently of the source: a single-sample
      // step of a 440 Hz sine at 48 kHz is bounded by 2π·f/sr. A dropped or
      // duplicated frame at the boundary exceeds it.
      let maximumStep = Float(2 * Double.pi * frequency / sampleRate) * 1.05
      for boundary in capture.boundaries.dropLast() {
        let index = Int(boundary)
        let step = abs(assembled[index] - assembled[index - 1])
        #expect(step <= maximumStep, "phase discontinuity at boundary \(boundary)")
      }
    }

    /// Regression: drain targets are sampled from the capture-wide frame
    /// counter, but each writer used to report progress from zero. The two
    /// domains coincide for the first file, so a single rotation looked
    /// healthy; from the second rotation on, the target was unreachable and
    /// every drain burned the full `writerDrainTimeout` before force-closing
    /// and recording a write failure.
    @Test
    func `every rotation drains promptly, not just the first`() async throws {
      let (engine, backend, _) = AIOEngine.fakeRecording()
      let outputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "RecordingRotationBoundaryTests-\(UUID().uuidString)",
          isDirectory: true,
        )
      defer { try? FileManager.default.removeItem(at: outputDirectory) }

      _ = try await engine.startRecording(
        configuration: makeConfiguration(outputDestination: .directory(outputDirectory)),
      )

      let clock = ContinuousClock()
      for rotation in 1...3 {
        backend.inject(channels: [ramp(1_024)])
        let started = clock.now
        _ = try await engine.rotateRecordingFile()
        let drained = await waitUntilDrained(engine, within: .seconds(1))
        #expect(drained, "rotation \(rotation) did not drain within a second")
        #expect(
          started.duration(to: clock.now) < engine.writerDrainTimeout,
          "rotation \(rotation) waited out the drain timeout",
        )
      }

      backend.inject(channels: [ramp(1_024)])
      let completion = try await engine.stopRecording()
      #expect(completion.boundaryFramePosition == 4_096)
    }

    /// Regression: a stop that lands while a rotation's drain is still in
    /// flight used to raise that drain's target from the boundary its file
    /// ends at to the capture's end. The frames in between went into the next
    /// file's ring, so the completed writer could never reach the new target:
    /// the drain waited out `writerDrainTimeout` and reported a failure for a
    /// file that was already complete. This cost the pre-existing
    /// `rotate recording file emits two files` test five seconds a run.
    @Test
    func `a stop during a rotation drain joins it instead of re-targeting it`() async throws {
      let (engine, backend, _) = AIOEngine.fakeRecording()
      let outputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "RecordingRotationBoundaryTests-\(UUID().uuidString)",
          isDirectory: true,
        )
      defer { try? FileManager.default.removeItem(at: outputDirectory) }
      let failures = FailureEventProbe()

      _ = try await engine.startRecording(
        configuration: makeConfiguration(outputDestination: .directory(outputDirectory)),
      )
      let bridge = await failures.bridge(to: engine)
      defer { bridge.cancelNow() }

      // Enough frames that the completed writer is still working through its
      // ring when the stop arrives.
      for chunk in ramp(16_384).chunked(into: 512) {
        #expect(backend.inject(channels: [chunk]))
      }
      let rotation = try await engine.rotateRecordingFile()

      let inFlight = await MainActor.run { engine.drainingWriterSessionIDs() }
      try #require(
        !inFlight.isEmpty,
        "the rotation's drain must still be in flight for this test to exercise anything",
      )

      // These belong to the new file, and are exactly what the old code
      // mistakenly demanded of the completed one.
      #expect(backend.inject(channels: [ramp(1_024)]))

      let clock = ContinuousClock()
      let started = clock.now
      let completion = try await engine.stopRecording()
      let elapsed = started.duration(to: clock.now)

      #expect(elapsed < engine.writerDrainTimeout, "the stop waited out a drain timeout")
      #expect(rotation.boundaryFramePosition == 16_384)
      #expect(completion.boundaryFramePosition == 17_408)

      // Each file was drained to its own boundary, not cut off by a timeout.
      #expect(try AVAudioFile(forReading: rotation.completedURL).length == 16_384)
      #expect(try AVAudioFile(forReading: completion.completedURL).length == 1_024)
      #expect(failures.count() == 0, "a complete file was reported as failed")
    }

    /// Regression: a rotation used to hand the tap fresh ring buffers, and a
    /// producer that landed between the boundary being sampled and the rings
    /// being replaced wrote into the completed file's ring while being counted
    /// past that file's boundary — frames belonging to one file, numbered
    /// against the next.
    ///
    /// Rotation now leaves the tap's rings alone and the completed writer
    /// stops reading at the boundary, so a producer cannot be on the wrong
    /// side of anything: whatever it writes before the switch is drained into
    /// the completed file, and whatever it writes after is left in the ring
    /// for the writer that takes over. This runs a producer flat out against a
    /// burst of rotations and asserts every file is exactly as long as its
    /// boundary claims — which fails both if the rings are swapped again and
    /// if the completed writer reads past its target.
    @Test
    func `a producer racing a rotation lands wholly on one side of it`() async throws {
      let (engine, backend, _) = AIOEngine.fakeRecording()
      let outputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "RecordingRotationBoundaryTests-\(UUID().uuidString)",
          isDirectory: true,
        )
      defer { try? FileManager.default.removeItem(at: outputDirectory) }

      let firstURL = try await engine.startRecording(
        configuration: makeConfiguration(outputDestination: .directory(outputDirectory)),
      )

      let injecting = ManagedAtomic<Bool>(true)
      let rejected = ManagedAtomic<Int>(0)
      // Single-frame writes: what decides whether this lands in a rotation's
      // critical section is how many times the producer enters one, not how
      // much audio it carries, and a low data rate keeps the writer ring from
      // overflowing and making dropped frames the thing under test.
      let producer = Task.detached {
        while injecting.load(ordering: .relaxed) {
          if !backend.inject(channels: [[0.5]]) {
            rejected.wrappingIncrement(ordering: .relaxed)
          }
          await Task.yield()
        }
      }

      var urls: [URL] = [firstURL]
      var boundaries: [Int64] = []
      for _ in 0..<12 {
        try await Task.sleep(for: .milliseconds(5))
        let rotation = try await engine.rotateRecordingFile()
        boundaries.append(rotation.boundaryFramePosition)
        urls.append(try #require(await MainActor.run { engine.currentRecordingURL() }))
      }

      // Quiesce the producer before stopping: frames injected after the stop
      // samples its target would be a different race, and not this one. The
      // final segment then gets a known payload of its own, so the last
      // boundary advances like every other.
      injecting.store(false, ordering: .relaxed)
      await producer.value
      #expect(backend.inject(channels: [ramp(512)]))

      let completion = try await engine.stopRecording()
      boundaries.append(completion.boundaryFramePosition)
      #expect(completion.completedURL == urls.last)

      try #require(
        rejected.load(ordering: .relaxed) == 0,
        "the writer ring overflowed, so dropped frames — not boundary placement — would be under test",
      )
      #expect(
        zip(boundaries, boundaries.dropFirst()).allSatisfy { $0 < $1 },
        "every rotation must advance the boundary",
      )

      let decodedLengths = try urls.map { try AVAudioFile(forReading: $0).length }
      let claimedLengths = zip(boundaries, [0] + boundaries).map { $0 - $1 }
      #expect(decodedLengths == claimedLengths)
      #expect(decodedLengths.reduce(0, +) == boundaries.last)
    }

    // MARK: - Capture harness

    private struct RotatedCapture {
      let engine: AIOEngine
      /// Directory holding every file of the capture; the caller removes it.
      let directory: URL
      /// Completed files, in capture order.
      let urls: [URL]
      /// The boundary reported for each completed file.
      let boundaries: [Int64]

      /// Frame length of each file, derived the way a consumer would: as the
      /// difference between adjacent boundaries.
      var segmentLengths: [Int64] {
        zip(boundaries, [0] + boundaries).map { $0 - $1 }
      }
    }

    /// Records one capture that rotates between each segment and stops after
    /// the last, collecting every reported boundary.
    private func record(segments: [[Float]]) async throws -> RotatedCapture {
      let (engine, backend, _) = AIOEngine.fakeRecording()
      let outputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "RecordingRotationBoundaryTests-\(UUID().uuidString)",
          isDirectory: true,
        )

      let firstURL = try await engine.startRecording(
        configuration: makeConfiguration(outputDestination: .directory(outputDirectory)),
      )

      var urls: [URL] = []
      var boundaries: [Int64] = []
      var framesInjected: Int64 = 0
      for (index, segment) in segments.enumerated() {
        // Injected in tap-sized chunks so the writer sees the same traffic
        // shape it would from a real capture callback, each carrying a host
        // time so the capture timing snapshot is populated the way a real tap
        // populates it.
        for chunk in segment.chunked(into: 512) {
          backend.inject(
            channels: [chunk],
            hostTime: UInt64(framesInjected) + 1,
            sourceSampleTime: framesInjected,
          )
          framesInjected += Int64(chunk.count)
        }

        if index == segments.indices.last {
          let completion = try await engine.stopRecording()
          urls.append(completion.completedURL)
          boundaries.append(completion.boundaryFramePosition)
        } else {
          let rotation = try await engine.rotateRecordingFile()
          urls.append(rotation.completedURL)
          boundaries.append(rotation.boundaryFramePosition)
          // Rotation hands the old writer's drain to a background task, so the
          // completed file is only readable once that task has finished.
          let drained = await waitUntilDrained(engine, within: .seconds(3))
          #expect(drained, "writer drain did not complete")
        }
      }

      #expect(urls.first == firstURL)
      #expect(Set(urls).count == urls.count, "each rotation must open a new file")
      return RotatedCapture(
        engine: engine,
        directory: outputDirectory,
        urls: urls,
        boundaries: boundaries,
      )
    }

    private func waitUntilDrained(_ engine: AIOEngine, within timeout: Duration) async -> Bool {
      let clock = ContinuousClock()
      let polling = PollingPolicy(interval: .milliseconds(5))
      let deadline = clock.now.advanced(by: timeout)
      while clock.now < deadline {
        if await MainActor.run(body: { engine.drainingWriterSessionIDs().isEmpty }) {
          return true
        }
        try? await polling.waitForNextPoll()
      }
      return await MainActor.run { engine.drainingWriterSessionIDs().isEmpty }
    }

    private func makeConfiguration(
      outputDestination: RecordingConfiguration.OutputDestination,
    ) -> RecordingConfiguration {
      RecordingConfiguration(
        inputConfiguration: InputConfiguration(sampleRate: .dvd, channels: .mono),
        // Float32 CAF round-trips the injected PCM bit-exactly, so a decoded
        // frame count is the written frame count and nothing else.
        outputConfiguration: OutputConfiguration(
          fileFormat: .caf,
          bitDepth: .pcmFloat32,
          quality: .high,
        ),
        outputDestination: outputDestination,
      )
    }

    // MARK: - Signal helpers

    private func ramp(_ count: Int) -> [Float] {
      (0..<count).map { Float($0) / Float(count) }
    }

    private func sine(frameCount: Int, frequency: Double, sampleRate: Double) -> [Float] {
      (0..<frameCount).map { index in
        Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
      }
    }

    private func readSamples(at url: URL) throws -> [Float] {
      let file = try AVAudioFile(forReading: url)
      let frameCount = AVAudioFrameCount(file.length)
      guard frameCount > 0 else { return [] }
      let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount),
      )
      try file.read(into: buffer)
      let channel = try #require(unsafe buffer.floatChannelData?[0])
      return unsafe Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
  }

  /// Counts `recordingFailed` events, which a drain timeout emits and a clean
  /// rotation must not.
  // SAFETY: the single counter is an atomic.
  private final class FailureEventProbe: Sendable {
    private let failures = ManagedAtomic<Int>(0)

    func count() -> Int {
      failures.load(ordering: .relaxed)
    }

    /// Subscribes before returning; the caller owns the returned handle.
    @MainActor
    func bridge(to engine: AIOEngine) -> FailureEventBridge {
      let subscription = engine.events.subscribe()
      let failures = failures
      let work = MainActorOwnedWork {
        for await event in subscription.events {
          if case .recordingFailed = event {
            failures.wrappingIncrement(ordering: .relaxed)
          }
        }
      }
      return FailureEventBridge(subscription: subscription, work: work)
    }
  }

  private struct FailureEventBridge: Sendable {
    let subscription: AsyncBroadcaster<AudioIOEvent>.Subscription
    let work: MainActorOwnedWork

    func cancelNow() {
      subscription.cancel()
      work.cancelNow()
    }
  }

  extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
      stride(from: 0, to: count, by: size).map {
        Array(self[$0..<Swift.min($0 + size, count)])
      }
    }
  }
#endif
