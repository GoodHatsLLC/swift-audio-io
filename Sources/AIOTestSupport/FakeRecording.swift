// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOAudioSession
  package import AIOContracts
  package import AIOEngineCore
  import Atomics
  package import AVFoundation
  import Foundation
  import Tools

  /// A tap installer that satisfies the seam without an `AVAudioEngine` graph.
  ///
  /// It builds a real `AVAudioConverter` and buffer, so everything downstream
  /// of the tap — conversion artifacts, tap configuration, the snapshot the
  /// lifecycle stages — is the genuine article. Only the graph mutation is
  /// skipped.
  package final class FakeTapInstaller: TapInstalling, @unchecked Sendable {
    /// Resolves the tap format for a zero-based install index. Returning `nil`
    /// uses the requested processing format, which is what a real tap reports
    /// when the route matches the configuration.
    private let tapFormatForInstall: @Sendable (Int) -> AVAudioFormat?
    private let failureForInstall: @Sendable (Int) -> RecordingError?
    private let onInstall: (@MainActor @Sendable () -> Void)?
    private let installCountStorage = ManagedAtomic<Int>(0)

    /// Varies behaviour per zero-based install index, so a test can start
    /// cleanly and have a later reinstall report a different format or fail.
    package init(
      tapFormatForInstall: @escaping @Sendable (Int) -> AVAudioFormat? = { _ in nil },
      failureForInstall: @escaping @Sendable (Int) -> RecordingError? = { _ in nil },
      onInstall: (@MainActor @Sendable () -> Void)? = nil,
    ) {
      self.tapFormatForInstall = tapFormatForInstall
      self.failureForInstall = failureForInstall
      self.onInstall = onInstall
    }

    /// Reports the same tap format for every install.
    package convenience init(tapFormat: AVAudioFormat) {
      self.init(tapFormatForInstall: { _ in tapFormat })
    }

    /// Fails every install.
    package convenience init(failure: RecordingError) {
      self.init(failureForInstall: { _ in failure })
    }

    /// Number of tap installs requested so far.
    package func installCount() -> Int {
      installCountStorage.load(ordering: .relaxed)
    }

    @MainActor
    package func installTap(
      configuration: RecordingConfiguration,
      processingFormat: AVAudioFormat,
    ) throws(RecordingError) -> TapInstallResult {
      let installIndex = installCountStorage.loadThenWrappingIncrement(ordering: .relaxed)
      onInstall?()
      if let failure = failureForInstall(installIndex) {
        throw failure
      }
      let resolvedTapFormat = tapFormatForInstall(installIndex) ?? processingFormat
      guard let converter = AVAudioConverter(from: resolvedTapFormat, to: processingFormat) else {
        throw RecordingError.formatConversionFailed
      }
      guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: 1_024) else {
        throw RecordingError.formatConversionFailed
      }
      return TapInstallResult(
        tapFormat: resolvedTapFormat,
        artifacts: TapConversionArtifacts(
          converter: converter,
          inputFormat: resolvedTapFormat,
          convertedBuffer: buffer,
        ),
        tapConfiguration: TapConfiguration(
          bus: 0,
          inputFormat: resolvedTapFormat,
          outputFormat: processingFormat,
          bufferSize: 1_024,
        ),
      )
    }
  }

  /// A capture backend that records lifecycle calls instead of driving audio
  /// hardware, and can push PCM into the real recording pipeline.
  package final class FakeCaptureBackend: RecordingCaptureBackend, @unchecked Sendable {
    private weak var owner: AIOEngine?
    private let startFailure: RecordingError?
    private let lock = Mut(FakeCaptureBackendState())

    private struct FakeCaptureBackendState {
      var startCalls = 0
      var cleanupCalls = 0
      var stopModes: [RecordingCaptureStopMode] = []
    }

    package init(owner: AIOEngine? = nil, startFailure: RecordingError? = nil) {
      self.owner = owner
      self.startFailure = startFailure
    }

    package func bind(owner: AIOEngine) {
      self.owner = owner
    }

    package var startCalls: Int { lock.withLock { $0.startCalls } }
    package var cleanupCalls: Int { lock.withLock { $0.cleanupCalls } }
    package var stopModes: [RecordingCaptureStopMode] { lock.withLock { $0.stopModes } }

    package func start() throws(RecordingError) {
      lock.withLock { $0.startCalls += 1 }
      if let startFailure {
        throw startFailure
      }
    }

    @MainActor
    package func stop(mode: RecordingCaptureStopMode) {
      lock.withLock { $0.stopModes.append(mode) }
      _ = owner?.state.consume(\.installedTapBus)
    }

    @MainActor
    package func cleanup() {
      lock.withLock { $0.cleanupCalls += 1 }
    }

    /// Pushes PCM through the same ring buffers the real tap callback writes
    /// to, so the writer and receiver loops see genuine traffic.
    package func inject(
      channels: [[Float]],
      hostTime: UInt64? = nil,
      sourceSampleTime: Int64? = nil,
      sourceSampleRate: Double? = nil,
    ) {
      owner?.injectRecordingSamples(
        channels: channels,
        hostTime: hostTime,
        sourceSampleTime: sourceSampleTime,
        sourceSampleRate: sourceSampleRate,
      )
    }
  }

  extension AIOEngine {
    /// Creates an engine whose recording lifecycle runs for real but whose
    /// audio-hardware collaborators are fakes.
    ///
    /// The returned engine executes the genuine
    /// `RecordingLifecycle.attemptRecordingStart` — deadline loop, retry
    /// classification, validation, ring-buffer and writer construction, event
    /// emission, abort reconciliation — while the tap install, engine start,
    /// and graph teardown are replaced.
    package static func fakeRecording(
      recordingStartTimeout: Duration = .seconds(2),
      audioSessionAuthority: (any AudioSessionAuthority)? = nil,
      tapInstaller: FakeTapInstaller = FakeTapInstaller(),
      backend: FakeCaptureBackend = FakeCaptureBackend(),
      onTeardown: (@MainActor @Sendable () -> Void)? = nil,
    ) -> (engine: AIOEngine, backend: FakeCaptureBackend, tapInstaller: FakeTapInstaller) {
      let engine = AIOEngine(
        audioSessionAuthority: audioSessionAuthority,
        recordingStartTimeout: recordingStartTimeout,
        recordingEnvironment: RecordingEnvironment(
          makeCaptureBackend: { _, engine in
            backend.bind(owner: engine)
            return backend
          },
          tapInstaller: tapInstaller,
          engineTeardown: { onTeardown?() },
        ),
      )
      backend.bind(owner: engine)
      return (engine, backend, tapInstaller)
    }

    /// Creates an engine whose readiness attempts are scripted, for exercising
    /// the start deadline loop and retry classification without a bring-up.
    ///
    /// This replaces one attempt inside the loop, so everything the loop itself
    /// owns — the deadline, transient-vs-terminal classification, cancellation,
    /// competing-start rejection — is still the production implementation.
    package static func scriptedStart(
      recordingStartTimeout: Duration = .seconds(2),
      attempt: @escaping @Sendable (RecordingConfiguration) async throws(RecordingError) -> URL,
    ) -> AIOEngine {
      AIOEngine(
        recordingStartTimeout: recordingStartTimeout,
        recordingEnvironment: RecordingEnvironment(attemptRecordingStart: attempt),
      )
    }
  }
#endif
