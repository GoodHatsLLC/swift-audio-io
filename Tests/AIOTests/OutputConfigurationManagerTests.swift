#if canImport(AVFoundation)
  import Testing

  @testable import AIOEngine

  @Suite
  struct OutputConfigurationManagerTests {

    @Test
    @MainActor
    func defaultConfigurationIsADTSHigh() throws {
      let env = AudioEnvironment()
      let errors = MockErrorManager()
      let manager = OutputConfigurationManager(env: env, errorManager: errors)

      #expect(manager.outputFormat == .adts)
      #expect(manager.bitDepth == .pcmFloat32)
      #expect(manager.encodingQuality == .high)

      let config = try #require(manager.outputConfiguration)
      #expect(config.fileFormat == .adts)
      #expect(config.bitDepth == .pcmFloat32)
      #expect(config.quality == .high)
    }

    @Test
    @MainActor
    func switchingToFlacAlignsBitDepthAndForcesMaximumQuality() throws {
      let env = AudioEnvironment()
      let errors = MockErrorManager()
      let manager = OutputConfigurationManager(env: env, errorManager: errors)

      // Start from a bit depth FLAC does not support.
      manager.bitDepth = .pcmFloat32
      manager.outputFormat = .flac

      // FLAC supports 16/24 only; the manager should align to the first supported.
      #expect(manager.bitDepth == .pcmInt16)

      // FLAC doesn't require quality -> only maximum is available and selected.
      #expect(manager.availableEncodingQualities == [.maximum])
      #expect(manager.encodingQuality == .maximum)

      let config = try #require(manager.outputConfiguration)
      #expect(config.fileFormat == .flac)
      #expect(config.bitDepth == .pcmInt16)
      #expect(config.quality == .maximum)
    }

    @Test
    @MainActor
    func switchingToWavKeepsBitDepthAndForcesMaximumQuality() throws {
      let env = AudioEnvironment()
      let errors = MockErrorManager()
      let manager = OutputConfigurationManager(env: env, errorManager: errors)

      manager.bitDepth = .pcmInt24
      manager.outputFormat = .wav

      // WAV supports all bit depths.
      #expect(manager.bitDepth == .pcmInt24)

      // WAV doesn't require quality -> maximum.
      #expect(manager.availableEncodingQualities == [.maximum])
      #expect(manager.encodingQuality == .maximum)

      let config = try #require(manager.outputConfiguration)
      #expect(config.fileFormat == .wav)
      #expect(config.bitDepth == .pcmInt24)
      #expect(config.quality == .maximum)
    }
  }
#endif

