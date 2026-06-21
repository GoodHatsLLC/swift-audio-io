// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOAudioSession
  import AIOContracts
  import AIOSupport
  package import AIOEngineCore
  import AVFoundation
  import os
  import Tools

  private let recordingSessionLog = SystemLog.make()

  extension AIOEngine {
    /// Activates the audio session via the (optional) `@MainActor` delegate.
    ///
    /// The delegate protocol is `@MainActor`, so activation cannot run on the
    /// off-main warm path. Callers perform this hop on the main actor *before*
    /// offloading the remaining (nonisolated) session configuration to
    /// ``configureAudioSession(for:sessionConfiguration:)``.
    @MainActor
    package func activateAudioSessionDelegate(
      _ sessionDelegate: (any AudioSessionDelegate)?,
    ) throws(SessionError) {
      do {
        try sessionDelegate?.setAudioSessionActive(true)
      } catch {
        throw .operationFailed(operation: .setActive, error: ErrorContext(error))
      }
    }

    package nonisolated func configureAudioSession(
      for configuration: RecordingConfiguration,
      sessionConfiguration: AudioSessionConfiguration,
    ) throws(SessionError) {
      #if os(iOS)
        let session = AVAudioSession.sharedInstance()

        try applyAudioSessionConfiguration(session, configuration: sessionConfiguration)

        do {
          try session.setPreferredSampleRate(configuration.format.sampleRate.hz)
        } catch {
          throw .operationFailed(operation: .setPreferredSampleRate, error: ErrorContext(error))
        }

        let preferredDuration = calculatePreferredBufferDuration(
          sampleRate: configuration.format.sampleRate.hz,
        )
        do {
          try session.setPreferredIOBufferDuration(preferredDuration)
        } catch {
          throw .operationFailed(
            operation: .setPreferredIOBufferDuration, error: ErrorContext(error),
          )
        }

        let desiredChannels = configuration.format.channels.platform
        let channelCount =
          desiredChannels > session.maximumInputNumberOfChannels
          ? AVAudioChannelCount(session.maximumInputNumberOfChannels) : desiredChannels
        do {
          try session.setPreferredInputNumberOfChannels(Int(channelCount))
        } catch {
          throw .operationFailed(
            operation: .setPreferredInputNumberOfChannels,
            error: ErrorContext(error),
          )
        }

        do {
          try session.setActive(true)
        } catch {
          throw .operationFailed(operation: .setActive, error: ErrorContext(error))
        }

        recordingSessionLog.info(
          "Audio session configured - Sample rate: \(session.sampleRate, privacy: .public), Buffer duration: \(session.ioBufferDuration, privacy: .public), Input channels: \(session.inputNumberOfChannels, privacy: .public)",
        )
      #else
        _ = configuration
      #endif
    }

    func calculatePreferredBufferDuration(sampleRate: Double) -> TimeInterval {
      let targetDuration = 0.02
      let baseSamples = targetDuration * sampleRate
      let adjustedSamples = max(baseSamples, 512)
      return adjustedSamples / sampleRate
    }
  }
#endif
