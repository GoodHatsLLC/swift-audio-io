// © GoodHatsLLC

#if os(iOS)
  import AIOSupport
  public import AVFAudio
  import Foundation
  public import Tools

  private let audioEnvironmentLifecycleLog = SystemLog.make()

  extension AudioEnvironmentManager {
    package struct AudioEnvironmentLifecycleRuntime {
      let owner: AudioEnvironmentManager

      @MainActor
      private func subscribeToOrientation(
        _ onChange: @MainActor (AVAudioSession.StereoOrientation) -> Void,
      ) async {
        let deviceInfo = PlatformDevice.create()

        let initial = await deviceInfo.currentOrientation
        onChange(initial.avAudioSessionOrientation)

        for await orientation in deviceInfo.orientationChanges() {
          onChange(orientation.avAudioSessionOrientation)
        }
      }

      @MainActor
      func run(sessionConfiguration: AudioSessionConfiguration) async throws(ManagerError) {
        guard !owner.isRunning else {
          throw .alreadyRunning
        }
        audioEnvironmentLifecycleLog.info("🔊 AudioEnvironmentManager.run() started")

        owner.isRunning = true
        defer { owner.isRunning = false }

        var isConfigured = false
        var configureAttempt = 0
        var configureRetryDelay: Duration = .milliseconds(100)
        let maxConfigureRetryDelay: Duration = .seconds(2)
        while !isConfigured {
          configureAttempt += 1
          do {
            try await owner.sessionBootstrap.configureInitialSession(
              configuration: sessionConfiguration,
            )
            isConfigured = true
          } catch {
            if Task.isCancelled {
              return
            }

            audioEnvironmentLifecycleLog.error(
              """
              Engine failed to configure audio session (attempt \(configureAttempt, privacy: .public)):
              \(String(describing: error), privacy: .public)
              Retrying in \(configureRetryDelay, privacy: .public)
              """,
            )
            try? await Task.sleep(for: configureRetryDelay)
            let nextRetryDelay = configureRetryDelay + configureRetryDelay
            configureRetryDelay =
              nextRetryDelay > maxConfigureRetryDelay ? maxConfigureRetryDelay : nextRetryDelay
          }
        }

        await subscribe()

        let wasActive = owner.isAudioSessionActive
        await withCancellationOperation {
          if wasActive {
            do {
              try owner.env.session.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
              audioEnvironmentLifecycleLog.error(
                "Failed to deactivate AudioSession on cancellation: \(error, privacy: .public)",
              )
            }
            await MainActor.run { owner.isAudioSessionActive = false }
          }
        }

        let deactivationSuffix = wasActive ? ", deactivating AudioSession" : ""
        audioEnvironmentLifecycleLog.info(
          "🔇AudioEnvironmentManager.run() finished\(deactivationSuffix, privacy: .public)",
        )
      }

      /// Subscribes to all AVAudioSession notification streams.
      ///
      /// ## Threading Contract
      ///
      /// Each `for await` loop consumes an `AsyncStream` from
      /// ``AudioEnvironment/Notifications``. The stream's `compactMap`/`map` closures
      /// execute on Apple's internal "AVAudioSession Notify Thread" (parsing only,
      /// no mutable state). The `for await` body inherits this method's `@MainActor`
      /// isolation, so all handlers dispatch to MainActor automatically.
      @MainActor
      private func subscribe() async {
        await withTaskGroup(of: Void.self) { group in
          let env = owner.env

          group.addTask { [weak owner] in
            for await notification in env.notifications.interruption {
              if Task.isCancelled { return }

              switch notification.type {
              case .began:
                await owner?.dispatchInterruption(
                  type: notification.type,
                  options: notification.options,
                )
              case .ended:
                await owner?.dispatchInterruption(
                  type: notification.type,
                  options: notification.options,
                )
              @unknown default:
                continue
              }
            }
          }
          group.addTask { [weak self] in
            for await _ in env.notifications.mediaServicesLost {
              if Task.isCancelled { return }
              await self?.handleMediaServicesLost()
            }
          }
          group.addTask { [weak self] in
            for await _ in env.notifications.mediaServicesReset {
              if Task.isCancelled { return }
              await self?.handleMediaServicesReset()
            }
          }
          owner.routeObserver.addTasks(to: &group)
          group.addTask { [weak self] in
            await self?.subscribeToOrientation { @MainActor [weak owner] orientation in
              guard let owner else { return }
              owner._orientation = orientation
              audioEnvironmentLifecycleLog.info(
                "orientation changed to: \(orientation.rawValue, privacy: .public)",
              )
              guard orientation != .none else { return }
              do {
                if owner.isConfiguredForStereo {
                  try owner.session.setPreferredInputOrientation(orientation)
                }
              } catch {
                owner.errorManager.enqueue(error)
              }
            }
          }

          group.addTask { @Sendable @MainActor [weak owner] in
            while !Task.isCancelled {
              guard let owner else { return }
              let pollInterval: Duration
              if owner.isAudioSessionActive {
                if let changes = owner.updateAudioInputs(reason: "periodic poll") {
                  audioEnvironmentLifecycleLog.info(
                    "􂡸 poll, device changes: \(changes, privacy: .public)",
                  )
                }
                pollInterval = .seconds(15)
              } else {
                pollInterval = .seconds(30)
              }
              try? await Task.sleep(for: pollInterval)
            }
          }

          group.addTask { [weak owner] in
            Task { @MainActor in
              owner?.isReady = true
              audioEnvironmentLifecycleLog.info("🔊 AudioEnvironmentManager ready")
            }
            await withCancellationOperation {
              Task { @MainActor in
                owner?.isReady = false
              }
              audioEnvironmentLifecycleLog.info("🔇AudioEnvironmentManager cancelled")
            }
          }

          await group.waitForAll()
        }
      }

      @MainActor
      private func handleMediaServicesLost() async {
        audioEnvironmentLifecycleLog.warning(
          "mediaServicesLost notification: audio services unavailable",
        )
        owner.isAudioSessionActive = false
        await owner.dispatchMediaServicesLost()
      }

      @MainActor
      private func handleMediaServicesReset() async {
        audioEnvironmentLifecycleLog.warning(
          "mediaServicesReset notification: rebuilding audio session configuration",
        )
        owner.isAudioSessionActive = false
        do {
          try owner.sessionBootstrap.rebuildSessionConfiguration(
            configuration: owner.sessionConfiguration,
          )
        } catch {
          owner.errorManager.enqueue(error)
        }
        await owner.restorePreferredInputAndConfigurationIfPossible(
          reason: "mediaServicesReset notification",
        )
        await owner.dispatchMediaServicesReset()
      }
    }
  }
#endif
