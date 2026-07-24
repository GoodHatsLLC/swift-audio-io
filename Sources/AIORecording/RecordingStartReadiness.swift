// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOEngineCore
  import AIORecordingSupport
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

  #if DEBUG
    struct ClosureRecordingStartReadiness: RecordingStartReadiness {
      let operation: @Sendable (RecordingConfiguration) async throws(RecordingError) -> URL

      func attempt(
        configuration: RecordingConfiguration,
      ) async throws(RecordingError) -> URL {
        try await operation(configuration)
      }
    }

    extension AIOEngine {
      @MainActor
      func setRecordingStartReadinessForTesting(
        _ readiness: (any RecordingStartReadiness)?,
      ) {
        guard let readiness else {
          recordingLifecycleState.recordingStartReadinessOverride = nil
          return
        }
        recordingLifecycleState.recordingStartReadinessOverride = {
          @Sendable configuration throws(RecordingError) in
          do {
            return try await readiness.attempt(configuration: configuration)
          } catch let error as RecordingError {
            throw error
          } catch {
            throw RecordingError.engineError
          }
        }
      }
    }
  #endif
#endif
