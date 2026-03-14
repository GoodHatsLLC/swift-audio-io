// © GoodHatsLLC

@MainActor
public protocol AudioSessionDelegate {
  func setAudioSessionActive(_: Bool) throws
}
