// © GoodHatsLLC

#if canImport(AVFoundation)
  import Foundation
  import Testing

  @testable import AIOAudioSession

  /// A self-contradictory request is reduced to a satisfiable one, never
  /// refused: channel layout › sample rate › bit depth › container.
  struct RecordingConfigurationReductionTests {
    @Test
    func `an exact high rate against AAC yields the container`() {
      let request = configuration(
        sampleRate: .exact(.hiRes96),
        fileFormat: .aac,
        destination: .temporary,
      )
      let (reduced, substitution) = request.reducedToEncodable()
      #expect(reduced.outputConfiguration.fileFormat == .caf)
      #expect(reduced.outputConfiguration.bitDepth == .pcmInt24)
      #expect(reduced.requestedFormat.exactSampleRate == .hiRes96)
      #expect(substitution == .containerReplaced(from: .aac, to: .caf, sampleRate: .hiRes96))
      #expect(reduced.validate().isValid)
    }

    @Test
    func `a caller-named file keeps its container and yields the rate`() {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).m4a")
      let request = configuration(
        sampleRate: .exact(.hiRes96),
        fileFormat: .aac,
        destination: .fileURL(url),
      )
      let (reduced, substitution) = request.reducedToEncodable()
      let clamped = FileFormat.aac.nearestSupportedSampleRate(to: .hiRes96)
      #expect(reduced.outputConfiguration.fileFormat == .aac)
      #expect(reduced.requestedFormat.exactSampleRate == clamped)
      #expect(substitution == .sampleRateClamped(from: .hiRes96, to: clamped, fileFormat: .aac))
    }

    @Test
    func `a satisfiable request is returned unchanged`() {
      let request = configuration(sampleRate: .exact(.dvd), fileFormat: .aac, destination: .temporary)
      let (reduced, substitution) = request.reducedToEncodable()
      #expect(reduced == request)
      #expect(substitution == nil)
    }

    @Test
    func `a hardware request is reduced once it resolves`() {
      let request = configuration(sampleRate: .hardware, fileFormat: .aac, destination: .temporary)
      #expect(request.reducedToEncodable().substitution == nil)

      let (resolved, substitution) = request.resolvedWithSubstitution(hardwareSampleRate: .hiRes96)
      #expect(resolved.outputConfiguration.fileFormat == .caf)
      #expect(resolved.requestedFormat.exactSampleRate == .hiRes96)
      #expect(substitution == .containerReplaced(from: .aac, to: .caf, sampleRate: .hiRes96))
    }

    private func configuration(
      sampleRate: RecordingSampleRate,
      fileFormat: FileFormat,
      destination: RecordingConfiguration.OutputDestination,
    ) -> RecordingConfiguration {
      RecordingConfiguration(
        input: .microphone(
          MicrophoneRecordingInput(
            format: CaptureFormat(sampleRate: sampleRate, channels: .mono),
          ),
        ),
        outputConfiguration: OutputConfiguration(
          fileFormat: fileFormat,
          bitDepth: nil,
          quality: .high,
        ),
        outputDestination: destination,
      )
    }
  }
#endif
