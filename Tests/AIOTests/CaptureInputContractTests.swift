// © GoodHatsLLC

#if canImport(AVFoundation)
  import Testing

  @testable import AIOAudioSession

  /// The contract a capture starts with is derived, never refused.
  struct CaptureInputContractTests {
    private let stereoInput = AudioInputSelection(
      id: "mic",
      name: "Stereo Mic",
      channelCount: .stereo,
    )

    @Test
    func `an explicit stereo request on a mono route keeps a stereo contract`() {
      let state = state(
        requested: request(channels: .stereo),
        applied: applied(channels: .mono, sampleRate: .dvd),
        reconciliation: .unsatisfied(.unsupportedChannels(.stereo)),
      )
      let contract = CaptureInputContract.derive(from: state)
      #expect(contract.settled.format.channels == .stereo)
      #expect(contract.settled.format.sampleRate == .dvd)
      #expect(contract.applied?.format.channels == .mono)
      #expect(contract.reconciliation == .unsatisfied(.unsupportedChannels(.stereo)))
    }

    @Test
    func `an automatic request takes what the platform applied`() {
      let state = state(
        requested: .automatic,
        applied: applied(channels: .mono, sampleRate: .cd),
        reconciliation: .satisfied,
      )
      let contract = CaptureInputContract.derive(from: state)
      #expect(contract.settled.format.channels == .mono)
      #expect(contract.settled.format.sampleRate == .cd)
    }

    @Test
    func `an automatic request with nothing applied follows the effective input`() {
      let state = state(
        requested: .automatic,
        applied: nil,
        reconciliation: .deferred(.sessionInactive),
      )
      let contract = CaptureInputContract.derive(from: state)
      #expect(contract.settled.format.channels == .stereo)
      #expect(contract.settled.format.sampleRate == .dvd)
      #expect(contract.settled.preferredInput == nil)
    }

    @Test
    func `a specific input that is absent yields no preferred input and keeps the request`() {
      var requested = AudioInputConfigurationRequest.automatic
      requested.input = .specific(id: "gone")
      let state = state(
        requested: requested,
        applied: nil,
        reconciliation: .deferred(.requestedInputUnavailable(id: "gone")),
      )
      let contract = CaptureInputContract.derive(from: state)
      #expect(contract.settled.preferredInput == nil)
      #expect(contract.reconciliation == .deferred(.requestedInputUnavailable(id: "gone")))
    }

    private func request(channels: AudioChannelPreference) -> AudioInputConfigurationRequest {
      var request = AudioInputConfigurationRequest.automatic
      request.channels = channels
      return request
    }

    private func applied(
      channels: ChannelCount,
      sampleRate: SampleRate,
    ) -> AppliedAudioInputConfiguration {
      AppliedAudioInputConfiguration(
        input: stereoInput,
        source: nil,
        format: InputConfiguration(sampleRate: sampleRate, channels: channels),
        processing: .processed,
      )
    }

    private func state(
      requested: AudioInputConfigurationRequest,
      applied: AppliedAudioInputConfiguration?,
      reconciliation: AudioInputConfigurationReconciliation,
    ) -> AudioInputConfigurationState {
      AudioInputConfigurationState(
        requested: requested,
        requestedGeneration: 1,
        applied: applied,
        capabilities: AudioInputConfigurationCapabilities(
          discovery: .resolved,
          inputs: [stereoInput],
          effectiveInput: stereoInput,
          sourceOptions: [],
          likelySampleRates: [.dvd],
          activeSampleRate: applied?.format.sampleRate,
        ),
        reconciliation: reconciliation,
      )
    }
  }
#endif
