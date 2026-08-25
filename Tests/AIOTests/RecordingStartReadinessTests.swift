// © GoodHatsLLC

#if canImport(AVFoundation)
  @testable import AIOEngineCore
  import AIOTestSupport
  import Foundation
  import Testing
  import Tools
  @testable import AudioIO

  @Suite(.serialized)
  struct RecordingStartReadinessTests {
    @MainActor
    @Test
    func `canonical start retries transient readiness then returns success`() async throws {
      let expectedURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("readiness-success-\(UUID().uuidString).caf")
      let readiness = ScriptedRecordingStartReadiness(
        steps: [
          .failure(.session(.notReady(details: "route still settling"))),
          .success(expectedURL),
        ],
      )
      let engine = AIOEngine.scriptedStart(recordingStartTimeout: .seconds(1)) { configuration throws(RecordingError) in
        try await readiness.attempt(configuration: configuration)
      }

      let actualURL = try await engine.startRecording(configuration: makeConfiguration())

      #expect(actualURL == expectedURL)
      #expect(await readiness.attemptCount() == 2)
    }

    @MainActor
    @Test
    func `canonical start preserves terminal failure without retry`() async {
      let readiness = ScriptedRecordingStartReadiness(
        steps: [.failure(.invalidConfiguration(details: "bad test configuration"))],
      )
      let engine = AIOEngine.scriptedStart(recordingStartTimeout: .seconds(1)) { configuration throws(RecordingError) in
        try await readiness.attempt(configuration: configuration)
      }
      let subscription = engine.events.subscribe()

      do {
        _ = try await engine.startRecording(configuration: makeConfiguration())
        Issue.record("Expected invalidConfiguration")
      } catch RecordingError.invalidConfiguration(let details) {
        #expect(details == "bad test configuration")
      } catch {
        Issue.record("Unexpected error: \(error)")
      }

      #expect(await readiness.attemptCount() == 1)
      subscription.cancel()
      var receivedEvent = false
      for await _ in subscription.events {
        receivedEvent = true
      }
      #expect(receivedEvent == false)
    }

    @MainActor
    @Test
    func `canonical start timeout retains last transient session failure`() async {
      let lastFailure = SessionError.notReady(details: "route still settling")
      let readiness = ScriptedRecordingStartReadiness(
        steps: [.failure(.session(lastFailure))],
      )
      let engine = AIOEngine.scriptedStart(recordingStartTimeout: .zero) { configuration throws(RecordingError) in
        try await readiness.attempt(configuration: configuration)
      }

      do {
        _ = try await engine.startRecording(configuration: makeConfiguration())
        Issue.record("Expected startTimedOut")
      } catch RecordingError.startTimedOut(let timeout, let actualLastFailure) {
        #expect(timeout == .zero)
        #expect(actualLastFailure == lastFailure)
      } catch {
        Issue.record("Unexpected error: \(error)")
      }
    }

    /// A route that has not switched to the preferred input by the deadline
    /// is not a reason to refuse: the loop takes one more attempt with the
    /// mismatch tolerated, so capture begins on the current input.
    @MainActor
    @Test
    func `route mismatch past the deadline earns one lenient attempt`() async throws {
      let expectedURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("readiness-lenient-\(UUID().uuidString).caf")
      let mismatch = SessionError.preferredInputRouteMismatch(
        id: "preferred",
        name: "Preferred Mic",
        currentInputIDs: ["built-in"],
      )
      let readiness = ScriptedRecordingStartReadiness(
        steps: [.failure(.session(mismatch)), .success(expectedURL)],
      )
      let tolerated = Synchronized<[Bool]>([])
      let engine = AIOEngine.scriptedStart(recordingStartTimeout: .zero) { configuration throws(RecordingError) in
        try await readiness.attempt(configuration: configuration)
      }
      let observe: @Sendable () -> Void = {
        tolerated.withLock { $0.append(engine.state[locked: \.toleratesPreferredInputMismatch]) }
      }
      await readiness.setOnAttempt(observe)

      let actualURL = try await engine.startRecording(configuration: makeConfiguration())

      #expect(actualURL == expectedURL)
      #expect(await readiness.attemptCount() == 2)
      // Strict on the first attempt, lenient on the one past the deadline.
      #expect(tolerated.withLock { $0 } == [false, true])
    }

    @MainActor
    @Test
    func `second concurrent start is rejected immediately`() async throws {
      let readiness = BlockingRecordingStartReadiness()
      let engine = AIOEngine.scriptedStart(recordingStartTimeout: .seconds(1)) { configuration throws(RecordingError) in
        try await readiness.attempt(configuration: configuration)
      }
      let configuration = makeConfiguration()

      let firstStart = Task {
        try await engine.startRecording(configuration: configuration)
      }
      await readiness.waitUntilAttempted()

      do {
        _ = try await engine.startRecording(configuration: configuration)
        Issue.record("Expected startInProgress")
      } catch RecordingError.startInProgress {
        // Expected.
      } catch {
        Issue.record("Unexpected error: \(error)")
      }

      let expectedURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("readiness-concurrent-\(UUID().uuidString).caf")
      readiness.succeed(with: expectedURL)
      let firstURL = try await firstStart.value
      #expect(firstURL == expectedURL)
    }

    @MainActor
    @Test
    func `cancelling start task surfaces typed cancellation`() async throws {
      let readiness = BlockingRecordingStartReadiness()
      let engine = AIOEngine.scriptedStart(recordingStartTimeout: .seconds(1)) { configuration throws(RecordingError) in
        try await readiness.attempt(configuration: configuration)
      }

      let start = Task {
        try await engine.startRecording(configuration: makeConfiguration())
      }
      await readiness.waitUntilAttempted()
      start.cancel()
      readiness.succeed(
        with: FileManager.default.temporaryDirectory
          .appendingPathComponent("readiness-cancelled-\(UUID().uuidString).caf"),
      )

      do {
        _ = try await start.value
        Issue.record("Expected cancelled")
      } catch RecordingError.cancelled {
        // Expected.
      } catch {
        Issue.record("Unexpected error: \(error)")
      }
    }

    private func makeConfiguration() -> RecordingConfiguration {
      RecordingConfiguration(
        inputConfiguration: InputConfiguration(sampleRate: .dvd, channels: .mono),
        outputConfiguration: OutputConfiguration(
          fileFormat: .caf,
          bitDepth: .pcmFloat32,
          quality: .high,
        ),
      )
    }
  }

  private actor ScriptedRecordingStartReadiness: RecordingStartReadiness {
    enum Step: Sendable {
      case success(URL)
      case failure(RecordingError)
    }

    private var steps: [Step]
    private var count = 0
    private var onAttempt: (@Sendable () -> Void)?

    init(steps: [Step]) {
      self.steps = steps
    }

    /// Observes each attempt as it begins, before its scripted outcome.
    func setOnAttempt(_ observer: @escaping @Sendable () -> Void) {
      onAttempt = observer
    }

    func attempt(
      configuration _: RecordingConfiguration,
    ) async throws(RecordingError) -> URL {
      onAttempt?()
      count += 1
      guard !steps.isEmpty else {
        throw RecordingError.engineError
      }
      switch steps.removeFirst() {
      case .success(let url):
        return url
      case .failure(let error):
        throw error
      }
    }

    func attemptCount() -> Int {
      count
    }
  }

  private final class BlockingRecordingStartReadiness: RecordingStartReadiness {
    private let attempted = AsyncContinuation<Void>()
    private let result = AsyncContinuation<URL>()

    func attempt(
      configuration _: RecordingConfiguration,
    ) async throws(RecordingError) -> URL {
      try? attempted.yield()
      return await result()
    }

    func waitUntilAttempted() async {
      await attempted()
    }

    func succeed(with url: URL) {
      try? result.yield(url)
    }
  }
#endif
