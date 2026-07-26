// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import Foundation
  import Tools

  /// One source-specific attempt to reach recording readiness and begin capture.
  ///
  /// The public engine interface owns deadlines and retry classification. This
  /// internal port keeps AVFoundation/Core Audio work behind one replaceable
  /// seam so deterministic tests can exercise the public start lifecycle.
  protocol RecordingStartReadiness: Sendable {
    func attempt(
      configuration: RecordingConfiguration,
    ) async throws(RecordingError) -> URL
  }

  struct PlatformRecordingStartReadiness: RecordingStartReadiness {
    let owner: AIOEngine

    @concurrent
    func attempt(
      configuration: RecordingConfiguration,
    ) async throws(RecordingError) -> URL {
      try await RecordingLifecycle(owner: owner).attemptRecordingStart(
        configuration: configuration,
      )
    }
  }

  /// Adapts an injected ``RecordingEnvironment/attemptRecordingStart`` closure
  /// to this port. The environment stores a closure rather than an
  /// `any RecordingStartReadiness` because the port is declared here, in
  /// `AIORecording`, which depends on `AIOEngineCore` where the environment
  /// lives.
  struct ClosureRecordingStartReadiness: RecordingStartReadiness {
    let operation: @Sendable (RecordingConfiguration) async throws(RecordingError) -> URL

    func attempt(
      configuration: RecordingConfiguration,
    ) async throws(RecordingError) -> URL {
      try await operation(configuration)
    }
  }
#endif
