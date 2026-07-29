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

      /// What one accepted activation request did once it reached the front of
      /// the activation queue.
      private enum ActivationOutcome: Sendable {
        /// Applied state already matched by the time this request's turn came,
        /// so no platform call was made.
        case alreadySatisfied
        /// The platform transition completed.
        case applied
        /// The platform transition failed.
        case failed(AudioSessionActivationError)
      }

      /// Requests a platform activation state and returns once the platform has
      /// settled it.
      ///
      /// Contract, unchanged from the synchronous implementation: applied state
      /// is written **only after** the activation succeeds, and the input
      /// configuration is reconciled (active) or marked unavailable (inactive)
      /// afterwards.
      ///
      /// Asynchronous activation adds a window where a second request arrives
      /// while the first is in flight, so three guards cooperate:
      ///
      /// 1. The entry guard compares against the newest *intent*, not applied
      ///    state alone. An opposite request arriving while one is in flight
      ///    would otherwise be measured against applied state the in-flight
      ///    request has not written yet, and be dropped as a false duplicate.
      /// 2. Requests are serialized on ``audioSessionActivationQueue``, and the
      ///    idempotence guard is re-checked **after** awaiting this request's
      ///    turn — a queued request that the platform already satisfied becomes
      ///    a no-op instead of a redundant platform call.
      /// 3. An activation generation is compared after the platform call, so a
      ///    superseded completion drops its follow-on reconciliation and lets
      ///    the superseding request own it. Applied state itself is *always*
      ///    written after a successful transition, because it mirrors the
      ///    platform rather than the request.
      @MainActor
      func setAudioSessionActive(_ active: Bool) async throws(ManagerError) {
        guard owner.isRunning else {
          audioSessionControllerLog.warning(
            "Cannot set audio session active state when manager is not running",
          )
          return
        }

        let intent = owner.requestedAudioSessionActive ?? owner.isAudioSessionActive
        if intent == active, owner.isAudioSessionActive == active {
          if active {
            await owner.reconcileInputConfiguration()
          }
          return
        }

        owner.requestedAudioSessionActive = active
        owner.audioSessionActivationGeneration &+= 1
        let generation = owner.audioSessionActivationGeneration
        let owner = owner
        let session = owner.env.session
        let activator = owner.sessionActivator

        let outcome = await owner.audioSessionActivationQueue.submit {
          () async -> ActivationOutcome in
          // Re-checked *after* awaiting this request's turn, so a request the
          // platform has meanwhile satisfied costs no platform call.
          let applied = await MainActor.run { owner.isAudioSessionActive }
          guard applied != active else { return .alreadySatisfied }

          do throws(AudioSessionActivationError) {
            try await activator.setActive(active, session: session)
          } catch {
            return .failed(error)
          }

          // Applied state mirrors the platform, so it is written here — at the
          // moment the transition is known to have happened — and not gated on
          // the generation. A superseded request still moved the platform, and
          // the request queued behind it must see that to decide whether it
          // needs a platform call of its own.
          await MainActor.run { owner.isAudioSessionActive = active }
          return .applied
        }

        switch outcome {
        case .none:
          // The queue was finished; no platform call ran and applied state is
          // untouched.
          return
        case .alreadySatisfied:
          if active, owner.audioSessionActivationGeneration == generation {
            await owner.reconcileInputConfiguration()
          }
          return
        case .failed(let error):
          // Release the intent so a retry is not swallowed by the entry guard,
          // but only if no newer request has claimed it.
          if owner.audioSessionActivationGeneration == generation {
            owner.requestedAudioSessionActive = owner.isAudioSessionActive
          }
          throw .audioSessionFailed(operation: .setActive, error: ErrorContext(error))
        case .applied:
          break
        }

        // Superseded: a newer request owns the follow-on reconciliation, so
        // stale completions do not churn input configuration on the way past.
        guard owner.audioSessionActivationGeneration == generation else {
          audioSessionControllerLog.info(
            "🔊 Audio session activation superseded; deferring reconciliation to the newer request",
          )
          return
        }

        audioSessionControllerLog.info(
          "🔊 Audio session manually set to \(active ? "active" : "inactive", privacy: .public)",
        )
        if active {
          await owner.reconcileInputConfiguration(forcePlatformApply: true)
        } else {
          owner.markInputConfigurationUnavailable(.sessionInactive)
        }
      }
    }
  }
#endif
