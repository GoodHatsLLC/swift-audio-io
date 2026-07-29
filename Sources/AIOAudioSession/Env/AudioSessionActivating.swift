// © GoodHatsLLC

#if os(iOS)
  import AIOSupport
  package import AVFAudio
  package import Tools
  import os

  private let activatorLog = SystemLog.make()

  /// The single seam through which AudioIO activates or deactivates the shared
  /// platform audio session.
  ///
  /// Every activation in the package goes through one of these — the
  /// environment manager's ``AudioEnvironmentManager/AudioSessionController``
  /// and both engine-managed fallback sites. That is deliberate: before this
  /// seam existed the engine reached for `AVAudioSession.setActive` directly and
  /// could interleave with controller-driven activation.
  ///
  /// Implementations must complete only when the platform has actually finished
  /// the transition, so callers may treat a normal return as evidence that the
  /// session reached the requested state.
  package protocol AudioSessionActivating: Sendable {
    func setActive(
      _ active: Bool,
      session: AVAudioSession,
    ) async throws(AudioSessionActivationError)
  }

  /// Why one activation attempt did not reach the requested state.
  package enum AudioSessionActivationError: Error, Sendable, CustomStringConvertible {
    /// The platform reported a failure.
    case platformFailed(ErrorContext)
    /// The platform completed without an error but declined the request.
    ///
    /// Only the iOS 27 asynchronous API can report this: it returns a
    /// success flag alongside its optional error.
    case refused(active: Bool)

    package var description: String {
      switch self {
      case .platformFailed(let error):
        "Audio session activation failed: \(error)"
      case .refused(let active):
        "Audio session declined to become \(active ? "active" : "inactive")"
      }
    }
  }

  /// iOS 26 path: the synchronous `setActive` call, serialized behind
  /// ``AudioSessionAccess`` so it cannot interleave with the synchronous route
  /// and preference reads that share the process-global session.
  package struct LegacyAudioSessionActivator: AudioSessionActivating {
    package init() {}

    package func setActive(
      _ active: Bool,
      session: AVAudioSession,
    ) async throws(AudioSessionActivationError) {
      try await AudioSessionAccess.result(catching: AudioSessionActivationError.self) {
        () throws(AudioSessionActivationError) -> Void in
        do {
          // `.notifyOthersOnDeactivation` is documented as valid only on
          // deactivation — it tells an interrupted app that it may resume.
          try session.setActive(active, options: active ? [] : .notifyOthersOnDeactivation)
        } catch {
          throw .platformFailed(ErrorContext(error))
        }
      }.get()
    }
  }

  /// iOS 27 path: the native asynchronous activation, which completes when the
  /// platform has finished the transition rather than blocking the caller's
  /// thread for the round-trip.
  ///
  /// This path deliberately does **not** hold ``AudioSessionAccess``. That gate
  /// exists to stop *synchronous* session calls from overlapping; holding a
  /// serial `DispatchQueue` across an `await` would pin it for the entire
  /// activation without adding safety. Activation requests are instead
  /// serialized by their caller — see
  /// ``AudioEnvironmentManager/AudioSessionController`` — and the synchronous
  /// reads keep using the gate on both OS versions.
  @available(iOS 27.0, *)
  package struct NativeAudioSessionActivator: AudioSessionActivating {
    package init() {}

    package func setActive(
      _ active: Bool,
      session: AVAudioSession,
    ) async throws(AudioSessionActivationError) {
      let honored: Bool
      do {
        if active {
          // `AVAudioSession.ActivationOptions` has no members other than the
          // empty set in the iOS 27.0 SDK.
          honored = try await session.activate(options: [])
        } else {
          // Preserves the legacy `.notifyOthersOnDeactivation` semantic. The
          // iOS 27 deactivation option set carries the same flag explicitly
          // (it is *not* implied); dropping it would stop other apps from
          // being told they may resume.
          honored = try await session.deactivate(options: .notifyOthersOnDeactivation)
        }
      } catch {
        throw .platformFailed(ErrorContext(error))
      }
      guard honored else {
        throw .refused(active: active)
      }
    }
  }

  /// Chooses the activation path once, at owner initialization, so the
  /// `#available` check is not repeated per request.
  package enum PlatformAudioSessionActivator {
    package static func make() -> any AudioSessionActivating {
      if #available(iOS 27.0, *) {
        activatorLog.info("Audio session activation: native asynchronous (iOS 27+)")
        return NativeAudioSessionActivator()
      } else {
        activatorLog.info("Audio session activation: legacy synchronous (iOS 26)")
        return LegacyAudioSessionActivator()
      }
    }
  }
#endif
