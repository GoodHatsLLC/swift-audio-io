// © GoodHatsLLC

#if canImport(AVFoundation)
  import AVFoundation
  import Testing
  @testable import AIOEngine

  struct RecordingConfigurationPCMSettingsTests {
    @Test
    func `aac settings use integer encoder quality value`() throws {
      for fileFormat in [FileFormat.adts, .aac] {
        let configuration = makeConfiguration(fileFormat: fileFormat)
        let settings = try #require(configuration.fileSettings)
        let qualityValue = try #require(settings[AVEncoderAudioQualityKey])

        #expect(
          qualityValue is Int,
          "Expected Int for \(AVEncoderAudioQualityKey), got \(String(describing: type(of: qualityValue))) for \(fileFormat.description)",
        )
        #expect(
          (qualityValue as? Int)
            == Int(configuration.outputConfiguration.quality.platform.rawValue),
        )
      }
    }

    @Test
    @MainActor
    func `aac recorder preflight produces usable format`() throws {
      for fileFormat in [FileFormat.adts, .aac] {
        let configuration = makeConfiguration(fileFormat: fileFormat)
        let (recorder, outputURL) = try makeRecorder(configuration: configuration)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let didPrepare = recorder.prepareToRecord()

        #expect(didPrepare, "prepareToRecord() failed for \(fileFormat.description)")
        #expect(
          recorder.format.sampleRate == configuration.inputConfiguration.sampleRate.rawValue,
          "Unexpected sample rate for \(fileFormat.description): \(recorder.format.sampleRate)",
        )
        #expect(
          recorder.format.channelCount == configuration.inputConfiguration.channels.platform,
          "Unexpected channel count for \(fileFormat.description): \(recorder.format.channelCount)",
        )
      }
    }

    @Test
    func `wav int24 uses packed24 bit PCM`() throws {
      let configuration = RecordingConfiguration(
        inputConfiguration: .init(
          sampleRate: .common(.sr48000),
          channels: .stereo,
        ),
        outputConfiguration: .init(
          fileFormat: .wav,
          bitDepth: .pcmInt24,
          quality: .maximum,
        ),
      )

      let settings = try #require(configuration.fileSettings)

      try #require(settings[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM)
      try #require(settings[AVLinearPCMBitDepthKey] as? Int == 24)
      try #require(settings[AVLinearPCMIsFloatKey] as? Bool == false)
      try #require(settings[AVLinearPCMIsBigEndianKey] as? Bool == false)
      try #require(settings[AVLinearPCMIsNonInterleaved] as? Bool == false)
    }

    @Test
    func `caf int24 uses linear PCM bit depth24`() throws {
      let configuration = RecordingConfiguration(
        inputConfiguration: .init(
          sampleRate: .common(.sr48000),
          channels: .stereo,
        ),
        outputConfiguration: .init(
          fileFormat: .caf,
          bitDepth: .pcmInt24,
          quality: .maximum,
        ),
      )

      let settings = try #require(configuration.fileSettings)

      try #require(settings[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM)
      try #require(settings[AVLinearPCMBitDepthKey] as? Int == 24)
    }

    @Test
    func `flac uses encoder bit depth hint`() throws {
      let configuration = RecordingConfiguration(
        inputConfiguration: .init(
          sampleRate: .common(.sr48000),
          channels: .stereo,
        ),
        outputConfiguration: .init(
          fileFormat: .flac,
          bitDepth: .pcmInt24,
          quality: .maximum,
        ),
      )

      let settings = try #require(configuration.fileSettings)

      try #require(settings[AVFormatIDKey] as? UInt32 == kAudioFormatFLAC)
      try #require(settings[AVEncoderBitDepthHintKey] as? Int == 24)
    }

    @Test
    func `aiff uses big endian linear PCM`() throws {
      let configuration = RecordingConfiguration(
        inputConfiguration: .init(
          sampleRate: .common(.sr48000),
          channels: .stereo,
        ),
        outputConfiguration: .init(
          fileFormat: .aiff,
          bitDepth: .pcmInt16,
          quality: .maximum,
        ),
      )

      let settings = try #require(configuration.fileSettings)

      try #require(settings[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM)
      try #require(settings[AVLinearPCMBitDepthKey] as? Int == 16)
      try #require(settings[AVLinearPCMIsFloatKey] as? Bool == false)
      try #require(settings[AVLinearPCMIsBigEndianKey] as? Bool == true)
      try #require(settings[AVLinearPCMIsNonInterleaved] as? Bool == false)
    }

    private func makeConfiguration(fileFormat: FileFormat) -> RecordingConfiguration {
      RecordingConfiguration(
        inputConfiguration: .init(
          sampleRate: .common(.sr48000),
          channels: .mono,
        ),
        outputConfiguration: .init(
          fileFormat: fileFormat,
          bitDepth: .pcmInt16,
          quality: .maximum,
        ),
      )
    }

    @MainActor
    private func makeRecorder(
      configuration: RecordingConfiguration,
    ) throws -> (recorder: AVAudioRecorder, outputURL: URL) {
      let settings = try #require(configuration.fileSettings)
      let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordingConfigurationPCMSettingsTests-\(UUID().uuidString)")
        .appendingPathExtension(configuration.fileExtension)

      let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
      return (recorder, outputURL)
    }
  }
#endif
