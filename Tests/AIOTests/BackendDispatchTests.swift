// © GoodHatsLLC

#if canImport(AVFoundation)
  import AVFoundation
  import Testing

  import AIORecordingSupport
  import AIOTestSupport
  @testable import AIOAudioSession
  @testable import AIORecording
  @testable import AudioIO

  /// SAFETY: only touched from the MainActor by the teardown test.
  private final class TeardownCounter: @unchecked Sendable {
    private(set) var value = 0
    func increment() { value += 1 }
  }

  // SAFETY: the test drives this entirely on the MainActor.
  private final class FakeCaptureBackend: RecordingCaptureBackend, @unchecked Sendable {
    private(set) var startCalls = 0
    private(set) var stopModes: [RecordingCaptureStopMode] = []
    private(set) var cleanupCalls = 0

    func start() throws(RecordingError) { startCalls += 1 }

    @MainActor
    func stop(mode: RecordingCaptureStopMode) { stopModes.append(mode) }

    @MainActor
    func cleanup() { cleanupCalls += 1 }
  }

  struct BackendDispatchTests {
    @MainActor
    @Test
    func `cleanUp tears down and clears the capture backend`() {
      let engine = AIOEngine()
      let backend = FakeCaptureBackend()
      engine.state[locked: \.captureBackend] = backend

      RecordingLifecycle(owner: engine).capture.cleanUp()

      #expect(backend.cleanupCalls == 1)
      #expect(engine.state.withLock { $0.captureBackend == nil })
    }

    @MainActor
    @Test
    func `hardStop immediately stops then cleans up the capture backend`() {
      let engine = AIOEngine()
      let backend = FakeCaptureBackend()
      engine.state[locked: \.captureBackend] = backend

      RecordingLifecycle(owner: engine).capture.hardStop()

      #expect(backend.stopModes == [.immediate])
      #expect(backend.cleanupCalls == 1)
      #expect(engine.state.withLock { $0.captureBackend == nil })
    }

    @MainActor
    @Test
    func `gracefulStop gracefully stops then cleans up the capture backend`() async {
      let engine = AIOEngine()
      let backend = FakeCaptureBackend()
      engine.state[locked: \.captureBackend] = backend

      await RecordingLifecycle(owner: engine).gracefulStop()

      #expect(backend.stopModes == [.graceful])
      #expect(backend.cleanupCalls == 1)
      #expect(engine.state.withLock { $0.captureBackend == nil })
      #expect(!engine.isRecording)
    }

    @MainActor
    @Test
    func `cleanUp without a backend is a no-op for the backend path`() {
      let engine = AIOEngine()
      RecordingLifecycle(owner: engine).capture.cleanUp()
      #expect(engine.state.withLock { $0.captureBackend == nil })
    }

    @MainActor
    @Test
    func `microphone backend owns graph teardown`() {
      let teardownCalls = TeardownCounter()
      let (engine, _, _) = AIOEngine.fakeRecording(onTeardown: { teardownCalls.increment() })
      engine.state[locked: \.captureBackend] = MicrophoneCaptureBackend(owner: engine)

      RecordingLifecycle(owner: engine).capture.hardStop()

      #expect(teardownCalls.value == 1)
      #expect(engine.state.withLock { $0.captureBackend == nil })
    }
  }
#endif
