// © GoodHatsLLC

public protocol AudioSessionAuthority: Sendable {
  /// Whether recording should use the platform's measurement-mode processing.
  @MainActor var recordingUsesMeasurementMode: Bool { get }

  /// Receives the engine's current demand for an active platform audio session.
  ///
  /// The authority remains responsible for deciding how that demand combines
  /// with other audio activity it owns.
  @MainActor func setAudioSessionActive(_: Bool) async throws
}

extension AudioSessionAuthority {
  @MainActor
  public var recordingUsesMeasurementMode: Bool { false }
}
