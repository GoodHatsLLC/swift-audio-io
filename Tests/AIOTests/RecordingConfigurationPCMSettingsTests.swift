#if canImport(AVFoundation)
  import AVFoundation
  import Testing

  @testable import AIOEngine

  @Suite
  struct RecordingConfigurationPCMSettingsTests {

    @Test
    func wavInt24UsesPacked24BitPCM() throws {
      let configuration = RecordingConfiguration(
        inputConfiguration: .init(
          sampleRate: .common(.sr48000),
          channels: .stereo
        ),
        outputConfiguration: .init(
          fileFormat: .wav,
          bitDepth: .pcmInt24,
          quality: .maximum
        )
      )

      let settings = try #require(configuration.fileSettings)

      try #require(settings[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM)
      try #require(settings[AVLinearPCMBitDepthKey] as? Int == 24)
      try #require(settings[AVLinearPCMIsFloatKey] as? Bool == false)
      try #require(settings[AVLinearPCMIsBigEndianKey] as? Bool == false)
      try #require(settings[AVLinearPCMIsNonInterleaved] as? Bool == false)
    }

    @Test
    func cafInt24UsesLinearPCMBitDepth24() throws {
      let configuration = RecordingConfiguration(
        inputConfiguration: .init(
          sampleRate: .common(.sr48000),
          channels: .stereo
        ),
        outputConfiguration: .init(
          fileFormat: .caf,
          bitDepth: .pcmInt24,
          quality: .maximum
        )
      )

      let settings = try #require(configuration.fileSettings)

      try #require(settings[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM)
      try #require(settings[AVLinearPCMBitDepthKey] as? Int == 24)
    }

    @Test
    func flacUsesEncoderBitDepthHint() throws {
      let configuration = RecordingConfiguration(
        inputConfiguration: .init(
          sampleRate: .common(.sr48000),
          channels: .stereo
        ),
        outputConfiguration: .init(
          fileFormat: .flac,
          bitDepth: .pcmInt24,
          quality: .maximum
        )
      )

      let settings = try #require(configuration.fileSettings)

      try #require(settings[AVFormatIDKey] as? UInt32 == kAudioFormatFLAC)
      try #require(settings[AVEncoderBitDepthHintKey] as? Int == 24)
    }

    @Test
    func aiffUsesBigEndianLinearPCM() throws {
      let configuration = RecordingConfiguration(
        inputConfiguration: .init(
          sampleRate: .common(.sr48000),
          channels: .stereo
        ),
        outputConfiguration: .init(
          fileFormat: .aiff,
          bitDepth: .pcmInt16,
          quality: .maximum
        )
      )

      let settings = try #require(configuration.fileSettings)

      try #require(settings[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM)
      try #require(settings[AVLinearPCMBitDepthKey] as? Int == 16)
      try #require(settings[AVLinearPCMIsFloatKey] as? Bool == false)
      try #require(settings[AVLinearPCMIsBigEndianKey] as? Bool == true)
      try #require(settings[AVLinearPCMIsNonInterleaved] as? Bool == false)
    }
  }
#endif
