// © GoodHatsLLC

#if os(iOS)
  import AIOSupport
  import AVFAudio
  import Tools
  import os

  private let audioSessionBootstrapLog = SystemLog.make()

  extension AudioEnvironmentManager {
    package struct AudioSessionBootstrap {
      let owner: AudioEnvironmentManager

      @MainActor
      func rebuildSessionConfiguration(configuration: AudioSessionConfiguration)
        throws(ManagerError)
      {
        try AudioEnvironmentManager.configureAudioSessionCategory(
          owner.env.session,
          configuration: configuration,
        )
      }

      @MainActor
      func configureInitialSession(configuration: AudioSessionConfiguration)
        async throws(ManagerError)
      {
        let env = owner.env
        try rebuildSessionConfiguration(configuration: configuration)

        do {
          try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
              do {
                try env.request(
                  input: env.input
                    ?? env.availableInputs.first(where: { $0.platform.portType == .builtInMic }),
                )
              } catch let error as AudioEnvironment.RequestError {
                throw ManagerError.audioEnvironment(error)
              }
            }
            try await group.waitForAll()
          }

          await owner.restorePreferredInputAndConfigurationIfPossible(reason: "run() startup")
          logConfiguredSession(for: env)
        } catch let error as ManagerError {
          logFailedSession(for: env, error: error)
          throw error
        } catch {
          let mapped = ManagerError.unexpected(ErrorContext(error))
          logFailedSession(for: env, error: mapped)
          throw mapped
        }
      }

      @MainActor
      private func logConfiguredSession(for env: AudioEnvironment) {
        audioSessionBootstrapLog.info(
          """
          🔊 AudioEnvironmentManager.run() configured AudioSession (inactive) with base settings:
          category: \(env.session.category.rawValue, privacy: .public)
          options: \(env.session.categoryOptions.description, privacy: .public)
          allowHapticsAndSystemSoundsDuringRecording: \(env.session.allowHapticsAndSystemSoundsDuringRecording, privacy: .public)
          prefersNoInterruptionsFromSystemAlerts: \(env.session.prefersNoInterruptionsFromSystemAlerts, privacy: .public)
          prefersInterruptionOnRouteDisconnect: \(env.session.prefersInterruptionOnRouteDisconnect, privacy: .public)
          """,
        )
      }

      @MainActor
      private func logFailedSession(for env: AudioEnvironment, error: ManagerError) {
        audioSessionBootstrapLog.error(
          """
          🔊 AudioEnvironmentManager.run() failed:
          category: \(env.session.category.rawValue, privacy: .public)
          options: \(env.session.categoryOptions.description, privacy: .public)
          allowHapticsAndSystemSoundsDuringRecording: \(env.session.allowHapticsAndSystemSoundsDuringRecording, privacy: .public)
          prefersNoInterruptionsFromSystemAlerts: \(env.session.prefersNoInterruptionsFromSystemAlerts, privacy: .public)
          prefersInterruptionOnRouteDisconnect: \(env.session.prefersInterruptionOnRouteDisconnect, privacy: .public)
          error: \(error, privacy: .public)
          """,
        )
      }
    }
  }
#endif
