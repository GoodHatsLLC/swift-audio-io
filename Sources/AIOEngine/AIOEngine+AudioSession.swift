#if !os(macOS) || targetEnvironment(macCatalyst)
  import AVFoundation
  import os
  import SystemLog
  import Tools

  private let log = SystemLog.make()

  extension AIOEngine {

    @MainActor
    func configureAudioSession(for configuration: RecordingConfiguration) throws(AIOError) {
      switch audioSessionPolicy {
      case .engineManaged:
        break
      case .delegated(let setActive):
        do {
          try setActive(true)
        } catch {
          throw .audioSessionFailed(operation: .setActive, error: ErrorContext(error))
        }
        return
      }

      let session = AVAudioSession.sharedInstance()

      try applyAudioSessionConfiguration(session, configuration: recordingSessionConfiguration)

      // Set preferred sample rate
      do {
        try session.setPreferredSampleRate(configuration.inputConfiguration.sampleRate.platform)
      } catch {
        throw .audioSessionFailed(operation: .setPreferredSampleRate, error: ErrorContext(error))
      }

      // Set preferred buffer duration for optimal performance
      let preferredDuration = calculatePreferredBufferDuration(
        sampleRate: configuration.inputConfiguration.sampleRate.platform
      )
      do {
        try session.setPreferredIOBufferDuration(preferredDuration)
      } catch {
        throw .audioSessionFailed(
          operation: .setPreferredIOBufferDuration, error: ErrorContext(error))
      }

      // Set preferred input channels if possible
      let desiredChannels = configuration.inputConfiguration.channels.platform
      let channelCount =
        desiredChannels > session.maximumInputNumberOfChannels
        ? AVAudioChannelCount(session.maximumInputNumberOfChannels) : desiredChannels
      do {
        try session.setPreferredInputNumberOfChannels(Int(channelCount))
      } catch {
        throw .audioSessionFailed(
          operation: .setPreferredInputNumberOfChannels, error: ErrorContext(error))
      }

      do {
        try session.setActive(true)
      } catch {
        throw .audioSessionFailed(operation: .setActive, error: ErrorContext(error))
      }

      // Verify actual settings
      log.info(
        "Audio session configured - Sample rate: \(session.sampleRate, privacy: .public), Buffer duration: \(session.ioBufferDuration, privacy: .public), Input channels: \(session.inputNumberOfChannels, privacy: .public)"
      )
    }

    @MainActor
    func configureAudioSessionForPlayback() throws(AIOError) {
      switch audioSessionPolicy {
      case .engineManaged:
        break
      case .delegated(let setActive):
        do {
          try setActive(true)
        } catch {
          throw .audioSessionFailed(operation: .setActive, error: ErrorContext(error))
        }
        return
      }

      let session = AVAudioSession.sharedInstance()
      // Don't change the audio session category for playback.
      // The existing .playAndRecord category already supports playback,
      // and switching categories can fail and break playback.
      do {
        try session.setActive(true)
      } catch {
        throw .audioSessionFailed(operation: .setActive, error: ErrorContext(error))
      }
    }

    @MainActor
    func applyAudioSessionConfiguration(
      _ session: AVAudioSession,
      configuration: AudioSessionConfiguration
    ) throws(AIOError) {

      if session.category != configuration.category
        || session.mode != configuration.mode
        || session.categoryOptions != configuration.options
      {
        do {
          try session.setCategory(
            configuration.category,
            mode: configuration.mode,
            options: configuration.options
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
            configuration.allowsHapticsAndSystemSoundsDuringRecording
          )
        } catch {
          throw .audioSessionFailed(
            operation: .setAllowHapticsAndSystemSoundsDuringRecording,
            error: ErrorContext(error)
          )
        }
      }

      if session.prefersNoInterruptionsFromSystemAlerts
        != configuration.prefersNoInterruptionsFromSystemAlerts
      {
        do {
          try session.setPrefersNoInterruptionsFromSystemAlerts(
            configuration.prefersNoInterruptionsFromSystemAlerts
          )
        } catch {
          throw .audioSessionFailed(
            operation: .setPrefersNoInterruptionsFromSystemAlerts,
            error: ErrorContext(error)
          )
        }
      }

      if session.prefersInterruptionOnRouteDisconnect
        != configuration.prefersInterruptionOnRouteDisconnect
      {
        do {
          try session.setPrefersInterruptionOnRouteDisconnect(
            configuration.prefersInterruptionOnRouteDisconnect
          )
        } catch {
          throw .audioSessionFailed(
            operation: .setPrefersInterruptionOnRouteDisconnect,
            error: ErrorContext(error)
          )
        }
      }
    }

    @MainActor
    func deactivateAudioSessionIfNeeded(reason: String) {
      guard deactivateAudioSessionOnStop else { return }
      guard !isRecording, !isPlayback, !wantsRecording else { return }

      if case .delegated(let setActive) = audioSessionPolicy {
        do {
          try setActive(false)
        } catch {
          let wrapped = AIOError.audioSessionFailed(
            operation: .setActive,
            error: ErrorContext(error)
          )
          log.error(
            "Failed to delegate audio session deactivation (\(reason, privacy: .public)): \(wrapped, privacy: .public)"
          )
          errorSubject.send(wrapped)
        }
        return
      }

      let session = AVAudioSession.sharedInstance()
      do {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
      } catch {
        let wrapped = AIOError.audioSessionFailed(
          operation: .setActive,
          error: ErrorContext(error)
        )
        log.error(
          "Failed to deactivate audio session (\(reason, privacy: .public)): \(wrapped, privacy: .public)"
        )
        errorSubject.send(wrapped)
      }
    }

    func calculatePreferredBufferDuration(sampleRate: Double) -> TimeInterval {
      let targetDuration = 0.02  // 20ms
      let baseSamples = targetDuration * sampleRate
      let adjustedSamples = max(baseSamples, 512)
      return adjustedSamples / sampleRate
    }
  }
#endif
