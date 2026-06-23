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
          // Route the startup `setPreferredInput` XPC through `inputWriteQueue`
          // (off-main + FIFO) rather than a one-off task group. The bindable
          // setters don't gate on readiness, so a UI binding could enqueue a
          // write during this cold-start window; funneling here keeps the
          // "input-preference writes never overlap" invariant intact.
          let requestError: (any Error)? = await owner.inputWriteQueue.submit {
            () -> (any Error)? in
            do {
              try env.request(
                input: env.input
                  ?? env.availableInputs.first(where: { $0.avAudio.portType == .builtInMic }),
              )
              return nil
            } catch {
              return error
            }
          } ?? nil
          if let requestError {
            // `request(input:)` only throws `RequestError`; the cast always
            // succeeds (the fallback is defensive).
            if let requestError = requestError as? AudioEnvironment.RequestError {
              throw ManagerError.audioEnvironment(requestError)
            }
            throw ManagerError.unexpected(ErrorContext(requestError))
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
