// © GoodHatsLLC

#if canImport(AVFoundation)
  import Testing

  @testable import AIOAudioSession

  struct RecordingInputTests {
    private func microphoneFormat() -> InputConfiguration {
      InputConfiguration(sampleRate: .dvd, channels: .init(platform: 1))
    }

    private func output() -> OutputConfiguration {
      OutputConfiguration(fileFormat: .caf, bitDepth: .pcmFloat32, quality: .high)
    }

    @Test
    func `convenience init builds a microphone source`() {
      let format = microphoneFormat()
      let configuration = RecordingConfiguration(
        inputConfiguration: format,
        outputConfiguration: output(),
        tapInterval: .milliseconds(50),
      )

      guard case .microphone(let microphone) = configuration.input else {
        Issue.record("Expected a .microphone input, got \(configuration.input)")
        return
      }
      #expect(microphone.format == format)
      #expect(microphone.tapInterval == .milliseconds(50))
    }

    @Test
    func `format accessor returns the source-specific format`() {
      let format = microphoneFormat()
      let configuration = RecordingConfiguration(
        input: .microphone(MicrophoneRecordingInput(format: format, tapInterval: .milliseconds(100))),
        outputConfiguration: output(),
      )
      #expect(configuration.format == format)
      #expect(configuration.input.format == format)
    }

    @Test
    func `tapInterval accessor reads the microphone interval`() {
      let configuration = RecordingConfiguration(
        input: .microphone(
          MicrophoneRecordingInput(format: microphoneFormat(), tapInterval: .milliseconds(25)),
        ),
        outputConfiguration: output(),
      )
      #expect(configuration.tapInterval == .milliseconds(25))
    }

    @Test
    func `convenience and explicit inits produce equal, equally-hashing configurations`() {
      let format = microphoneFormat()
      let viaConvenience = RecordingConfiguration(
        inputConfiguration: format,
        outputConfiguration: output(),
        tapInterval: .milliseconds(100),
      )
      let viaExplicit = RecordingConfiguration(
        input: .microphone(MicrophoneRecordingInput(format: format, tapInterval: .milliseconds(100))),
        outputConfiguration: output(),
      )
      #expect(viaConvenience == viaExplicit)
      #expect(viaConvenience.hashValue == viaExplicit.hashValue)
    }

    @Test
    func `different tap intervals are not equal`() {
      let format = microphoneFormat()
      let a = RecordingConfiguration(inputConfiguration: format, outputConfiguration: output(), tapInterval: .milliseconds(50))
      let b = RecordingConfiguration(inputConfiguration: format, outputConfiguration: output(), tapInterval: .milliseconds(100))
      #expect(a != b)
    }
  }
#endif
