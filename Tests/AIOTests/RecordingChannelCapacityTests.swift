// © GoodHatsLLC

#if canImport(AVFoundation)
  @testable import AIOEngineCore
  import Testing

  import AVFoundation
  @testable import AIOAudioSession
  @testable import AudioIO
  struct RecordingChannelCapacityTests {
    @Test
    @MainActor
    func `starting unsupported runtime channel count emits typed error`() async throws {
      let engine = AIOEngine()
      let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("unsupported-start-\(UUID().uuidString).caf")
      defer { try? FileManager.default.removeItem(at: outputURL) }
      let configuration = makeConfiguration(
        fileFormat: .caf,
        channels: .init(platform: 33),
        outputDestination: .fileURL(outputURL),
      )

      do {
        _ = try await engine.startRecording(configuration: configuration)
        Issue.record("Expected unsupportedChannelCount")
      } catch RecordingError.unsupportedChannelCount(
        let requested,
        let maximum
      ) {
        #expect(requested == 33)
        #expect(maximum == 32)
      } catch {
        Issue.record("Expected unsupportedChannelCount, got \(error)")
      }

      #expect(engine.isRecording == false)
      #expect(FileManager.default.fileExists(atPath: outputURL.path) == false)
    }

    @Test
    func `format-specific unsupported channel count emits typed error`() throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration(fileFormat: .flac, channels: .init(platform: 9))

      do {
        try RecordingLifecycle(owner: engine).capture.validateRecordingChannelCapacity(
          for: configuration,
        )
        Issue.record("Expected unsupportedChannelCount")
      } catch RecordingError.unsupportedChannelCount(
        let requested,
        let maximum
      ) {
        #expect(requested == 9)
        #expect(maximum == 8)
      } catch {
        Issue.record("Expected unsupportedChannelCount, got \(error)")
      }
    }

    @Test
    func `runtime allocates the requested supported channel count`() {
      let engine = AIOEngine()

      let buffers = RecordingLifecycle(owner: engine).capture.makeAudioBuffers(
        sampleRate: 48_000,
        channelCount: 32,
      )

      #expect(buffers.count == 32)
      #expect(buffers.allSatisfy { $0.capacity > 0 })
    }

    @Test
    func `declared channel matrix is accepted before engine setup`() throws {
      let engine = AIOEngine()
      let cases: [(FileFormat, Int)] = [
        (.aac, 1),
        (.aac, 2),
        (.aac, 8),
        (.adts, 1),
        (.adts, 2),
        (.adts, 8),
        (.flac, 1),
        (.flac, 2),
        (.flac, 4),
        (.flac, 8),
        (.caf, 1),
        (.caf, 2),
        (.caf, 4),
        (.caf, 32),
        (.wav, 1),
        (.wav, 2),
        (.wav, 4),
        (.wav, 32),
        (.aiff, 1),
        (.aiff, 2),
        (.aiff, 4),
        (.aiff, 32),
      ]

      for (fileFormat, channelCount) in cases {
        let configuration = makeConfiguration(
          fileFormat: fileFormat,
          channels: .init(platform: AVAudioChannelCount(channelCount)),
        )

        try RecordingLifecycle(owner: engine).capture.validateRecordingChannelCapacity(
          for: configuration,
        )
        #expect(
          configuration.processingFormat?.channelCount
            == AVAudioChannelCount(channelCount),
          "Invalid processing format for \(fileFormat.description) \(channelCount)ch",
        )
        #expect(
          configuration.fileSettings != nil,
          "Missing file settings for \(fileFormat.description) \(channelCount)ch",
        )
      }
    }

    @Test
    @MainActor
    func `writer flushes declared multichannel format edges`() throws {
      let cases: [(FileFormat, Int)] = [
        (.aac, 8),
        (.adts, 8),
        (.flac, 8),
        (.caf, 32),
        (.wav, 32),
        (.aiff, 32),
      ]

      for (fileFormat, channelCount) in cases {
        let engine = AIOEngine()
        let configuration = makeConfiguration(
          fileFormat: fileFormat,
          channels: .init(platform: AVAudioChannelCount(channelCount)),
        )
        let processingFormat = try #require(configuration.processingFormat)
        let buffers = RecordingLifecycle(owner: engine).capture.makeAudioBuffers(
          sampleRate: 48_000,
          channelCount: channelCount,
        )
        let frameCount = 1024
        for channelIndex in 0..<channelCount {
          let samples = (0..<frameCount).map { frameIndex in
            Float(channelIndex + 1) / 100 + Float(frameIndex) / 1_000_000
          }
          _ = unsafe samples.withUnsafeBufferPointer { source in
            unsafe buffers[channelIndex].write(source)
          }
        }

        let outputURL = FileManager.default.temporaryDirectory
          .appendingPathComponent("RecordingChannelCapacityTests-\(UUID().uuidString)")
          .appendingPathExtension(configuration.fileExtension)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let writer = try engine.makeRecordingWriter(
          url: outputURL,
          configuration: configuration,
          writerBackend: engine.recordingLifecycleState.writerBackend,
        )

        let result = RecordingLifecycle.Writer.flushChunk(
          size: frameCount,
          from: buffers,
          in: processingFormat,
          to: writer,
        )
        writer.close()

        switch result {
        case .success(let write):
          #expect(write.framesRead == frameCount)
        case .failure(let error):
          Issue.record(
            "Expected \(fileFormat.description) \(channelCount)ch write to succeed, got \(error)",
          )
        }

        let fileSize = try #require(outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(fileSize > 0, "Expected \(outputURL.lastPathComponent) to contain audio data")
      }
    }

    private func makeConfiguration(
      fileFormat: FileFormat,
      channels: ChannelCount,
      outputDestination: RecordingConfiguration.OutputDestination = .temporary,
    ) -> RecordingConfiguration {
      RecordingConfiguration(
        inputConfiguration: InputConfiguration(
          sampleRate: .dvd,
          channels: channels,
        ),
        outputConfiguration: OutputConfiguration(
          fileFormat: fileFormat,
          bitDepth: bitDepth(for: fileFormat),
          quality: .high,
        ),
        outputDestination: outputDestination,
      )
    }

    private func bitDepth(for fileFormat: FileFormat) -> BitDepth {
      switch fileFormat {
      case .flac:
        .pcmInt24
      case .aiff:
        .pcmInt16
      case .caf, .wav, .aac, .adts:
        .pcmFloat32
      }
    }
  }
#endif
