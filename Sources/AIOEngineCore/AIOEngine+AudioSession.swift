// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOContracts
  import AIOSupport
  #if os(iOS)
    package import AVFoundation
  #else
    import AVFoundation
  #endif
  import os
  import Tools

  private let log = SystemLog.make()

  extension AIOEngine {
    @MainActor
    package func configureAudioSessionForPlayback() async throws(SessionError) {
      try await setAudioSessionDemand(active: true)
    }

    @MainActor
    package func setAudioSessionDemand(active: Bool) async throws(SessionError) {
      do {
        if let audioSessionAuthority {
          try await audioSessionAuthority.setAudioSessionActive(active)
        } else {
          #if os(iOS)
            try AVAudioSession.sharedInstance().setActive(active)
          #endif
        }
      } catch {
        throw .operationFailed(operation: .setActive, error: ErrorContext(error))
      }
    }

    #if os(iOS)
      package nonisolated func applyAudioSessionConfiguration(
        _ session: AVAudioSession,
        configuration: AudioSessionConfiguration,
      ) throws(SessionError) {
        if session.category != configuration.category
          || session.mode != configuration.mode
          || session.categoryOptions != configuration.options
        {
          do {
            try session.setCategory(
              configuration.category,
              mode: configuration.mode,
              options: configuration.options,
            )
          } catch {
            throw .operationFailed(operation: .setCategory, error: ErrorContext(error))
          }
        }

        if session.allowHapticsAndSystemSoundsDuringRecording
          != configuration.allowsHapticsAndSystemSoundsDuringRecording
        {
          do {
            try session.setAllowHapticsAndSystemSoundsDuringRecording(
              configuration.allowsHapticsAndSystemSoundsDuringRecording,
            )
          } catch {
            throw .operationFailed(
              operation: .setAllowHapticsAndSystemSoundsDuringRecording,
              error: ErrorContext(error),
            )
          }
        }

        if session.prefersNoInterruptionsFromSystemAlerts
          != configuration.prefersNoInterruptionsFromSystemAlerts
        {
          do {
            try session.setPrefersNoInterruptionsFromSystemAlerts(
              configuration.prefersNoInterruptionsFromSystemAlerts,
            )
          } catch {
            throw .operationFailed(
              operation: .setPrefersNoInterruptionsFromSystemAlerts,
              error: ErrorContext(error),
            )
          }
        }

        if session.prefersInterruptionOnRouteDisconnect
          != configuration.prefersInterruptionOnRouteDisconnect
        {
          do {
            try session.setPrefersInterruptionOnRouteDisconnect(
              configuration.prefersInterruptionOnRouteDisconnect,
            )
          } catch {
            throw .operationFailed(
              operation: .setPrefersInterruptionOnRouteDisconnect,
              error: ErrorContext(error),
            )
          }
        }
      }
    #endif

    @MainActor
    package func deactivateAudioSessionIfNeeded(reason: String) async {
      guard !isRecording, !isPlayback, recordingLifecycleState.startOperationID == nil else {
        return
      }

      do {
        try await setAudioSessionDemand(active: false)
      } catch let wrapped {
        log.error(
          "Failed to release audio session demand (\(reason, privacy: .public)): \(wrapped, privacy: .public)",
        )
        eventSubject.send(AudioIOEvent.error(wrapped))
      }
    }
  }
#endif
