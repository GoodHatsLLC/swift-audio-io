// © GoodHatsLLC

#if canImport(AVFoundation)
  import AVFoundation
  import Testing

  import AIORecordingSupport
  @testable import AIOAudioSession
  @testable import AIORecording
  @_spi(TESTING) @testable import AudioIO

  // SAFETY: the test drives this entirely on the MainActor.
  private final class FakeCaptureBackend: RecordingCaptureBackend, @unchecked Sendable {
    let sourceFormat: AVAudioFormat
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var cleanupCalls = 0

    init(sourceFormat: AVAudioFormat) { self.sourceFormat = sourceFormat }

    func start() throws(RecordingError) { startCalls += 1 }
    func stop() throws(RecordingError) { stopCalls += 1 }
    func cleanup() { cleanupCalls += 1 }
  }

  struct BackendDispatchTests {
    private func format() -> AVAudioFormat {
      AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    }

    @MainActor
    @Test
    func `cleanUp tears down and clears the active backend`() {
      let engine = AIOEngine()
      let backend = FakeCaptureBackend(sourceFormat: format())
      engine.state[locked: \.activeBackend] = backend

      engine.cleanUp()

      #expect(backend.cleanupCalls == 1)
      #expect(engine.state.withLock { $0.activeBackend == nil })
    }

    @MainActor
    @Test
    func `hardStop routes teardown through the active backend`() {
      let engine = AIOEngine()
      let backend = FakeCaptureBackend(sourceFormat: format())
      engine.state[locked: \.activeBackend] = backend

      // With an active backend, hardStop must not touch the AVAudioEngine input
      // tap; teardown flows through cleanUp() -> backend.cleanup().
      engine.hardStop()

      #expect(backend.cleanupCalls == 1)
      #expect(engine.state.withLock { $0.activeBackend == nil })
    }

    @MainActor
    @Test
    func `gracefulStop stops then cleans up the active backend`() async {
      let engine = AIOEngine()
      let backend = FakeCaptureBackend(sourceFormat: format())
      engine.state[locked: \.activeBackend] = backend

      await engine.gracefulStop()

      #expect(backend.stopCalls == 1)
      #expect(backend.cleanupCalls == 1)
      #expect(engine.state.withLock { $0.activeBackend == nil })
      #expect(!engine.isRecording)
    }

    @MainActor
    @Test
    func `cleanUp without a backend is a no-op for the backend path`() {
      let engine = AIOEngine()
      // No backend set (microphone/legacy path).
      engine.cleanUp()
      #expect(engine.state.withLock { $0.activeBackend == nil })
    }
  }
#endif
