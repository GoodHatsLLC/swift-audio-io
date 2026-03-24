// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOContracts
  import AIOSupport
  import AVFoundation
  import os
  import Tools

  private let log = SystemLog.make()

  extension AIOEngine {
    @MainActor
    package func configureAudioSessionForPlayback() throws(AIOError) {
      do {
        try audioSessionDelegate?.setAudioSessionActive(true)
      } catch {
        throw .audioSessionFailed(operation: .setActive, error: ErrorContext(error))
      }
    }

    #if os(iOS)
      @MainActor
      func applyAudioSessionConfiguration(
        _ session: AVAudioSession,
        configuration: AudioSessionConfiguration,
      ) throws(AIOError) {
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
            throw .audioSessionFailed(operation: .setCategory, error: ErrorContext(error))
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
            throw .audioSessionFailed(
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
            throw .audioSessionFailed(
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
            throw .audioSessionFailed(
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
        let wrapped = AIOError.audioSessionFailed(
          operation: .setActive,
          error: ErrorContext(error),
        )
        log.error(
          "Failed to delegate audio session deactivation (\(reason, privacy: .public)): \(wrapped, privacy: .public)",
        )
        errorSubject.send(wrapped)
      }
    }
  }
#endif
