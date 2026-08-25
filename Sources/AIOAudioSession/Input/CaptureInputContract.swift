// © GoodHatsLLC

#if canImport(AVFoundation)
  /// The microphone contract a capture starts with, derived from the request
  /// against whatever the environment offers right now.
  ///
  /// Derivation never refuses. An explicit channel layout is the contract
  /// whether or not the route can supply it — a mono route is replicated into
  /// a stereo file by the engine — and an automatic layout takes what the
  /// platform applied, or the effective input's own width while nothing is
  /// applied. The sample rate is a *seed* for callers that need a number
  /// before bring-up; a `.hardware` request re-resolves it against the route
  /// when the tap installs.
  ///
  /// ``reconciliation`` and ``applied`` travel with the contract so a caller
  /// can say how the request stands ("Stereo · using mono") without treating
  /// that standing as a reason not to start.
  public struct CaptureInputContract: Hashable, Sendable {
    public let settled: SettledMicrophoneInputConfiguration
    public let reconciliation: AudioInputConfigurationReconciliation
    public let applied: AppliedAudioInputConfiguration?

    public init(
      settled: SettledMicrophoneInputConfiguration,
      reconciliation: AudioInputConfigurationReconciliation,
      applied: AppliedAudioInputConfiguration?,
    ) {
      self.settled = settled
      self.reconciliation = reconciliation
      self.applied = applied
    }

    public static func derive(from state: AudioInputConfigurationState) -> CaptureInputContract {
      let requested = state.requested
      let applied = state.applied
      let capabilities = state.capabilities

      let channels: ChannelCount
      if let exact = requested.channels.exactChannelCount {
        channels = exact
      } else if let applied {
        channels = applied.format.channels
      } else if let effectiveInput = capabilities.effectiveInput {
        channels = effectiveInput.channelCount >= .stereo ? .stereo : .mono
      } else {
        channels = .mono
      }

      let sampleRate = applied?.format.sampleRate ?? capabilities.activeSampleRate ?? .dvd

      let preferredInput: AudioInputSelection?
      switch requested.input {
      case .systemDefault:
        preferredInput = nil
      case .specific(let id):
        preferredInput =
          capabilities.inputs.first(where: { $0.id == id })
          ?? applied.flatMap { $0.input.id == id ? $0.input : nil }
      }

      return CaptureInputContract(
        settled: SettledMicrophoneInputConfiguration(
          format: InputConfiguration(sampleRate: sampleRate, channels: channels),
          preferredInput: preferredInput,
          source: applied?.source,
          requestGeneration: state.requestedGeneration,
        ),
        reconciliation: state.reconciliation,
        applied: applied,
      )
    }
  }
#endif
