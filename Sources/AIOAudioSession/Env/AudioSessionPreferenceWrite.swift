// © GoodHatsLLC

#if os(iOS)
  package import AVFAudio

  /// Writes an `AVAudioSession` preference only when the session does not
  /// already read the requested value back.
  ///
  /// ## Why this exists
  ///
  /// Every `AVAudioSession` preference write is a potential
  /// `AVAudioSession.routeChangeNotification` — most often with
  /// `.categoryChange`. This package reconciles input configuration on every
  /// such notification, and a live recording reconsiders its tap on every one
  /// too. So a write that changes nothing is not free: it costs a full
  /// reconciliation pass, and can cost a tap teardown. Where the platform
  /// offers a readback, comparing first is both cheaper and quieter than
  /// writing blindly.
  ///
  /// Only preferences with an honest readback belong here. `setActive` has
  /// none in the sense that matters — activation is a transition, not a stored
  /// preference — so it stays on its own serialized path.
  package enum AudioSessionPreferenceWrite {
    /// - Returns: `true` when the platform write was actually performed.
    @discardableResult
    package static func perform<Value: Equatable>(
      _ desired: Value,
      whenNot current: @autoclosure () -> Value,
      write: (Value) throws -> Void,
    ) rethrows -> Bool {
      guard current() != desired else { return false }
      try write(desired)
      return true
    }

    /// The preferred-input variant, which compares port identity rather than
    /// the `AVAudioSessionPortDescription` reference.
    ///
    /// - Returns: `true` when the platform write was actually performed.
    @discardableResult
    package static func performPreferredInput(
      _ desired: AVAudioSessionPortDescription?,
      on session: AVAudioSession,
      write: (AVAudioSessionPortDescription?) throws -> Void,
    ) rethrows -> Bool {
      guard session.preferredInput?.uid != desired?.uid else { return false }
      try write(desired)
      return true
    }
  }
#endif
