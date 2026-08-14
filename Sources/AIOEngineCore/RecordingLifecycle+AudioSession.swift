// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOAudioSession
  import AIOContracts
  import AIOSupport
  import AVFoundation
  import os
  import Tools

  private let recordingSessionLog = SystemLog.make()

  extension RecordingLifecycle {
    /// Asks the engine's immutable audio-session authority to satisfy active demand.
    ///
    /// The authority method is `@MainActor`, so authority-driven activation
    /// cannot run on the off-main graph-preparation path. Callers perform this
    /// hop on the main actor *before* offloading the remaining (nonisolated)
    /// session configuration to
    /// ``configureAudioSession(for:sessionConfiguration:)``.
    ///
    /// Engine-managed activation is *not* hoisted here. It has to stay ordered
    /// after category, mode, and preferred I/O values are applied — activating
    /// before the category is set would activate under whatever category the
    /// process last had — so it happens mid-way through
    /// ``configureAudioSession(for:sessionConfiguration:)`` instead.
    @MainActor
    package func activateAudioSessionAuthority() async throws(SessionError) {
      guard owner.audioSessionAuthority != nil else { return }
      try await owner.setAudioSessionDemand(active: true)
    }

    /// Applies the recording session configuration and, in engine-managed mode,
    /// activates the session at the point in that sequence where it has always
    /// happened.
    ///
    /// Asynchronous because iOS 27 activation is asynchronous. The synchronous
    /// configuration work is still done in ``AudioSessionAccess`` blocks; only
    /// the activation await sits between them, so the gate is released for the
    /// duration of the platform round-trip rather than held across it.
    package nonisolated func configureAudioSession(
      for configuration: RecordingConfiguration,
      sessionConfiguration: AudioSessionConfiguration,
    ) async throws(SessionError) {
      #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try applyOutputPreferences(
          for: configuration,
          sessionConfiguration: sessionConfiguration,
          session: session,
        )

        if owner.audioSessionAuthority == nil {
          // Shared activation path. Previously a raw synchronous
          // `session.setActive(true)` inlined between these two blocks.
          try await owner.activateSharedSession(active: true)
        }

        try applyInputPreferences(for: configuration, session: session)
      #else
        _ = configuration
      #endif
    }

    #if os(iOS)
      /// Category, mode, sample rate, and buffer duration. Everything that must
      /// be applied *before* the session is activated.
      ///
      /// Split out so the synchronous ``AudioSessionAccess`` overload is
      /// selected: inside an `async` function Swift prefers the asynchronous
      /// overload, which would put this blocking work on the cooperative pool
      /// instead of the access queue.
      private nonisolated func applyOutputPreferences(
        for configuration: RecordingConfiguration,
        sessionConfiguration: AudioSessionConfiguration,
        session: AVAudioSession,
      ) throws(SessionError) {
        try AudioSessionAccess.result(catching: SessionError.self) {
          () throws(SessionError) -> Void in
          try owner.applyAudioSessionConfiguration(session, configuration: sessionConfiguration)

          // Idempotent, like the category block above it: a redundant
          // preference write posts a route-change notification, which this
          // package reconciles on and — mid-recording — reconsiders the tap on.
          do {
            try AudioSessionPreferenceWrite.perform(
              configuration.format.sampleRate.hz,
              whenNot: session.preferredSampleRate,
            ) { try session.setPreferredSampleRate($0) }
          } catch {
            throw .operationFailed(operation: .setPreferredSampleRate, error: ErrorContext(error))
          }

          let preferredDuration = calculatePreferredBufferDuration(
            sampleRate: configuration.format.sampleRate.hz,
          )
          do {
            try AudioSessionPreferenceWrite.perform(
              preferredDuration,
              whenNot: session.preferredIOBufferDuration,
            ) { try session.setPreferredIOBufferDuration($0) }
          } catch {
            throw .operationFailed(
              operation: .setPreferredIOBufferDuration, error: ErrorContext(error),
            )
          }
        }.get()
      }

      /// Preferred input and channel count, which are only meaningful once the
      /// session is active and a route exists.
      private nonisolated func applyInputPreferences(
        for configuration: RecordingConfiguration,
        session: AVAudioSession,
      ) throws(SessionError) {
        try AudioSessionAccess.result(catching: SessionError.self) {
          () throws(SessionError) -> Void in
          try applyPreferredInputIfNeeded(for: configuration, session: session)

          let desiredChannels = Int(configuration.format.channels.platform)
          try RecordingInputChannelContract.validateRouteCapacity(
            requested: desiredChannels,
            maximum: session.maximumInputNumberOfChannels,
          )
          do {
            try AudioSessionPreferenceWrite.perform(
              desiredChannels,
              whenNot: session.preferredInputNumberOfChannels,
            ) { try session.setPreferredInputNumberOfChannels($0) }
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
      }
    #endif

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
          try AudioSessionPreferenceWrite.performPreferredInput(port, on: session) {
            try session.setPreferredInput($0)
          }
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
