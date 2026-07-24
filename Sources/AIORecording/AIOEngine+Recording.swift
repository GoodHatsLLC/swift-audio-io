// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOEngineCore
  import AIORecordingSupport
  import Atomics
  import Foundation

  /// Consumer-facing recording facade. Recording lifecycle implementation and
  /// state live behind `RecordingLifecycle`.
  extension AIOEngine {
    /// Starts recording audio with the specified configuration and returns the
    /// destination URL once the engine is producing output.
    ///
    /// This is the canonical start entry point. It stops active playback and
    /// retries transient capture readiness failures within
    /// ``AIOEngine/recordingStartTimeout``.
    public nonisolated func startRecording(
      configuration: RecordingConfiguration,
    ) async throws(RecordingError) -> URL {
      try await recordingLifecycle.startRecording(configuration: configuration)
    }

    /// Updates the microphone input-tap cadence for the active or next
    /// recording. System-audio capture ignores this microphone-only setting.
    @MainActor
    public func updateRecordingTapInterval(_ interval: Duration) {
      recordingLifecycle.updateRecordingTapInterval(interval)
    }

    /// Stops the current recording and returns the URL of the recorded file.
    @MainActor
    public func stopRecording() async throws(RecordingError) -> URL {
      try await recordingLifecycle.stopRecording()
    }

    /// Rotates the recording to a new file without interrupting audio capture.
    @MainActor
    public func rotateRecordingFile() async throws(RecordingError) -> URL {
      try await recordingLifecycle.rotateRecordingFile()
    }

    /// The host-time interval and exact persisted frame counts of the current
    /// or most recently finished recording segment.
    @MainActor
    public func recordingTimingSnapshot() -> RecordingTimingSnapshot? {
      let firstHostTime = recordingFirstHostTimeAtomic.load(ordering: .acquiring)
      guard firstHostTime != 0 else { return nil }
      let rawSampleTime = recordingFirstSourceSampleTimeAtomic.load(ordering: .relaxed)
      return RecordingTimingSnapshot(
        firstBufferHostTime: firstHostTime,
        firstBufferSampleTime: rawSampleTime == Int64.min ? nil : rawSampleTime,
        lastBufferHostTime: recordingLastHostTimeAtomic.load(ordering: .acquiring),
        capturedFrameCount: recordingCapturedFrameCountAtomic.load(ordering: .relaxed),
        hostTimeSpanFrameCount: recordingHostTimeSpanFrameCountAtomic.load(ordering: .relaxed),
      )
    }
  }
#endif
