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
        await owner.reconcileInputConfiguration()
        logConfiguredSession(for: env)
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

    }
  }
#endif
