// © GoodHatsLLC

@MainActor
public protocol AudioSessionDelegate {
  /// Whether recording should use the platform's measurement-mode processing.
  var recordingUsesMeasurementMode: Bool { get }

  func setAudioSessionActive(_: Bool) async throws
}

extension AudioSessionDelegate {
  public var recordingUsesMeasurementMode: Bool { false }
}
