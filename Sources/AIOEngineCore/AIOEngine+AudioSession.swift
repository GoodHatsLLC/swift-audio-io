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
    package func configureAudioSessionForPlayback() throws(SessionError) {
      do {
        try audioSessionDelegate?.setAudioSessionActive(true)
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
    package func deactivateAudioSessionIfNeeded(reason: String) {
      guard deactivateAudioSessionOnStop else { return }
      guard !isRecording, !isPlayback, !wantsRecording else { return }

      do {
        try audioSessionDelegate?.setAudioSessionActive(false)
      } catch {
        let wrapped = SessionError.operationFailed(
          operation: .setActive,
          error: ErrorContext(error),
        )
        log.error(
          "Failed to delegate audio session deactivation (\(reason, privacy: .public)): \(wrapped, privacy: .public)",
        )
        eventSubject.send(AudioIOEvent.error(wrapped))
      }
    }
  }
#endif
