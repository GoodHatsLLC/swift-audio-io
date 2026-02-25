#if canImport(AVFoundation)
  import AudioSignals
  import AVFoundation
  import Testing

  @Suite("OfflineLODExtractor Tests")
  struct OfflineLODExtractorTests {
    @Test("extract produces result with correct metadata")
    func extractProducesResult() async throws {
      let sampleRate: Double = 44100
      let frameCount: AVAudioFrameCount = 44100  // 1 second
      let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
      guard let buffer else { return }
      buffer.frameLength = frameCount

      if let channelData = unsafe buffer.floatChannelData {
        let twoPiFrequency = 2.0 * Double.pi * 440.0
        for i in 0..<Int(frameCount) {
          let t = Double(i) / sampleRate
          unsafe channelData[0][i] = Float(sin(twoPiFrequency * t))
        }
      }

      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("caf")
      defer { try? FileManager.default.removeItem(at: url) }

      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      try file.write(from: buffer)

      let extractor = OfflineLODExtractor(configuration: .default)
      let result = try await extractor.extract(from: url)

      #expect(result.bandCount == MultiBandLODConfiguration.default.bandCount)
      #expect(result.sampleRate == sampleRate)
      #expect(result.durationSeconds > 0.9 && result.durationSeconds < 1.1)
      #expect(result.snapshot.writeIndex > 0)
    }

    @Test("extract from segments concatenates correctly")
    func extractFromSegments() async throws {
      let sampleRate: Double = 44100
      let frameCount: AVAudioFrameCount = 88200  // 2 seconds
      let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
      guard let buffer else { return }
      buffer.frameLength = frameCount

      if let channelData = unsafe buffer.floatChannelData {
        for i in 0..<Int(frameCount) {
          let t = Double(i) / sampleRate
          unsafe channelData[0][i] = Float(sin(2.0 * .pi * 440.0 * t))
        }
      }

      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("caf")
      defer { try? FileManager.default.removeItem(at: url) }

      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      try file.write(from: buffer)

      let extractor = OfflineLODExtractor(configuration: .default)
      let result = try await extractor.extract(from: url, segments: [0.0...0.5, 1.0...1.5])

      // Should be ~1 second total (two 0.5s segments)
      #expect(result.durationSeconds > 0.9 && result.durationSeconds < 1.1)
      #expect(result.snapshot.writeIndex > 0)
    }
  }
#endif
