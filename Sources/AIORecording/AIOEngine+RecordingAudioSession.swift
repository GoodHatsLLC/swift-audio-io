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
    @MainActor
    package func configureAudioSession(for configuration: RecordingConfiguration) throws(AIOError) {
      do {
        try audioSessionDelegate?.setAudioSessionActive(true)
      } catch {
        throw .audioSessionFailed(operation: .setActive, error: ErrorContext(error))
      }

      #if os(iOS)
        let session = AVAudioSession.sharedInstance()

        try applyAudioSessionConfiguration(session, configuration: recordingSessionConfiguration)

        do {
          try session.setPreferredSampleRate(configuration.inputConfiguration.sampleRate.hz)
        } catch {
          throw .audioSessionFailed(operation: .setPreferredSampleRate, error: ErrorContext(error))
        }

        let preferredDuration = calculatePreferredBufferDuration(
          sampleRate: configuration.inputConfiguration.sampleRate.hz,
        )
        do {
          try session.setPreferredIOBufferDuration(preferredDuration)
        } catch {
          throw .audioSessionFailed(
            operation: .setPreferredIOBufferDuration, error: ErrorContext(error),
          )
        }

        let desiredChannels = configuration.inputConfiguration.channels.platform
        let channelCount =
          desiredChannels > session.maximumInputNumberOfChannels
          ? AVAudioChannelCount(session.maximumInputNumberOfChannels) : desiredChannels
        do {
          try session.setPreferredInputNumberOfChannels(Int(channelCount))
        } catch {
          throw .audioSessionFailed(
            operation: .setPreferredInputNumberOfChannels,
            error: ErrorContext(error),
          )
        }

        do {
          try session.setActive(true)
        } catch {
          throw .audioSessionFailed(operation: .setActive, error: ErrorContext(error))
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
