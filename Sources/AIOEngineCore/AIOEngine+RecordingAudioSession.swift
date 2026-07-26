// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOAudioSession
  import AIOContracts
  import AIOSupport
  import AVFoundation
  import os
  import Tools

  private let recordingSessionLog = SystemLog.make()

  extension AIOEngine {
    /// Asks the engine's immutable audio-session authority to satisfy active demand.
    ///
    /// The authority method is `@MainActor`, so activation cannot run on the
    /// off-main graph-preparation path. Callers perform this hop on the main actor *before*
    /// offloading the remaining (nonisolated) session configuration to
    /// ``configureAudioSession(for:sessionConfiguration:)``.
    @MainActor
    package func activateAudioSessionAuthority() async throws(SessionError) {
      // Engine-managed iOS activation happens only after category, mode, and
      // preferred I/O values have been applied in `configureAudioSession`.
      guard audioSessionAuthority != nil else { return }
      try await setAudioSessionDemand(active: true)
    }

    package nonisolated func configureAudioSession(
      for configuration: RecordingConfiguration,
      sessionConfiguration: AudioSessionConfiguration,
    ) throws(SessionError) {
      #if os(iOS)
        try AudioSessionAccess.result(catching: SessionError.self) {
          () throws(SessionError) -> Void in
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

          if audioSessionAuthority == nil {
            do {
              try session.setActive(true)
            } catch {
              throw .operationFailed(operation: .setActive, error: ErrorContext(error))
            }
          }

          try applyPreferredInputIfNeeded(for: configuration, session: session)

          let desiredChannels = Int(configuration.format.channels.platform)
          try RecordingInputChannelContract.validateRouteCapacity(
            requested: desiredChannels,
            maximum: session.maximumInputNumberOfChannels,
          )
          do {
            try session.setPreferredInputNumberOfChannels(desiredChannels)
          } catch {
            throw .operationFailed(
              operation: .setPreferredInputNumberOfChannels,
              error: ErrorContext(error),
            )
          }
          try RecordingInputChannelContract.validateCaptureFormat(
            requested: desiredChannels,
            actual: session.inputNumberOfChannels,
          )

          recordingSessionLog.info(
            "Audio session configured - Sample rate: \(session.sampleRate, privacy: .public), Buffer duration: \(session.ioBufferDuration, privacy: .public), Input channels: \(session.inputNumberOfChannels, privacy: .public)",
          )
        }.get()
      #else
        _ = configuration
      #endif
    }

    #if os(iOS)
      private nonisolated func applyPreferredInputIfNeeded(
        for configuration: RecordingConfiguration,
        session: AVAudioSession,
      ) throws(SessionError) {
        guard case .microphone(let microphone) = configuration.input,
          let preferredInput = microphone.preferredInput
        else {
          return
        }

        guard let port = session.availableInputs?.first(where: { $0.uid == preferredInput.id })
        else {
          throw .preferredInputUnavailable(id: preferredInput.id, name: preferredInput.name)
        }

        do {
          try session.setPreferredInput(port)
        } catch {
          throw .operationFailed(operation: .setPreferredInput, error: ErrorContext(error))
        }

        let currentInputIDs = session.currentRoute.inputs.map(\.uid)
        guard currentInputIDs.contains(preferredInput.id) else {
          throw .preferredInputRouteMismatch(
            id: preferredInput.id,
            name: preferredInput.name,
            currentInputIDs: currentInputIDs,
          )
        }
      }
    #endif

    func calculatePreferredBufferDuration(sampleRate: Double) -> TimeInterval {
      let targetDuration = 0.02
      let baseSamples = targetDuration * sampleRate
      let adjustedSamples = max(baseSamples, 512)
      return adjustedSamples / sampleRate
    }
  }
#endif
