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
      func setAudioSessionActive(_ active: Bool) throws(ManagerError) {
        guard owner.isRunning else {
          audioSessionControllerLog.warning(
            "Cannot set audio session active state when manager is not running",
          )
          return
        }
        do {
          try owner.env.session.setActive(active, options: .notifyOthersOnDeactivation)
        } catch {
          throw .audioSessionFailed(operation: .setActive, error: ErrorContext(error))
        }
        owner.isAudioSessionActive = active
        audioSessionControllerLog.info(
          "🔊 Audio session manually set to \(active ? "active" : "inactive", privacy: .public)",
        )
        if active {
          owner.callbackTasks.run { [weak owner] in
            await owner?.restorePreferredInputAndConfigurationIfPossible(
              reason: "audio session activated",
            )
          }
        }
      }
    }
  }
#endif
