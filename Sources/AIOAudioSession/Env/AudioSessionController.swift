// © GoodHatsLLC

#if os(iOS)
  import AIOSupport
  import AVFAudio
  import Tools
  import os

  private let audioSessionControllerLog = SystemLog.make()

  extension AudioEnvironmentManager {
    package struct AudioSessionController {
      let owner: AudioEnvironmentManager

      @MainActor
      func setAudioSessionActive(_ active: Bool) async throws(ManagerError) {
        guard owner.isRunning else {
          audioSessionControllerLog.warning(
            "Cannot set audio session active state when manager is not running",
          )
          return
        }
        guard owner.isAudioSessionActive != active else {
          if active {
            await owner.waitForInputPreferenceRestorationIfNeeded()
          }
          return
        }

        let session = owner.env.session
        try await AudioSessionAccess.result(catching: AudioEnvironmentManager.ManagerError.self) {
          () throws(AudioEnvironmentManager.ManagerError) -> Void in
          do {
            try session.setActive(active, options: .notifyOthersOnDeactivation)
          } catch {
            throw .audioSessionFailed(operation: .setActive, error: ErrorContext(error))
          }
        }.get()
        owner.isAudioSessionActive = active
        audioSessionControllerLog.info(
          "🔊 Audio session manually set to \(active ? "active" : "inactive", privacy: .public)",
        )
        if active {
          // Activation is a readiness boundary, not merely a request to
          // `AVAudioSession`. Callers build recording configurations as soon as
          // this method returns, so the cached route/input state and persisted
          // channel preferences must already match the active session.
          await owner.restorePreferredInputAndConfigurationIfPossible(
            reason: "audio session activated",
          )
        }
      }
    }
  }
#endif
