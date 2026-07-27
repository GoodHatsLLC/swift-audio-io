// © GoodHatsLLC

#if os(iOS)
  import AIOSupport
  import AVFAudio
  import os

  private let audioRouteObserverLog = SystemLog.make()

  extension AudioEnvironmentManager {
    package struct AudioRouteObserver {
      let owner: AudioEnvironmentManager

      func addTasks(to group: inout TaskGroup<Void>) {
        let env = owner.env
        group.addTask { [weak owner] in
          for await _ in env.notifications.availableInputsChanged {
            guard let owner else { return }
            await owner.reconcileInputConfiguration()
          }
        }
        group.addTask { [weak owner] in
          for await notification in env.notifications.routeChange {
            audioRouteObserverLog.info(
              "Route change notification: \(String(describing: notification), privacy: .public)",
            )
            if Task.isCancelled { return }
            guard let owner else { return }
            await owner.reconcileInputConfiguration()

            let event = AudioRouteChange(
              platformReason: notification.reason,
              previousRoute: notification.previous,
              session: env.session,
            )
            await owner.dispatchAudioSystemEvent(.routeChanged(event))
          }
        }
      }
    }
  }
#endif
