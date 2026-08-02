// © GoodHatsLLC

#if canImport(AVFoundation)
  import AudioSignals
  import AVFoundation
  import Testing

  struct OfflineLODExtractorTests {
    @Test
    func `extract reports immutable progress on the static file timeline`() async throws {
      let sampleRate: Double = 44100
      let frameCount: AVAudioFrameCount = 44100
      let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
      let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
      buffer.frameLength = frameCount

      if let channelData = unsafe buffer.floatChannelData {
        for frame in 0..<Int(frameCount) {
          let time = Double(frame) / sampleRate
          unsafe channelData[0][frame] = Float(sin(2.0 * .pi * 440.0 * time))
        }
      }

      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("caf")
      defer { try? FileManager.default.removeItem(at: url) }

      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      try file.write(from: buffer)

      let recorder = ProgressRecorder()
      let result = try await OfflineLODExtractor(configuration: .default).extract(
        from: url,
        onProgress: { progress in
          await recorder.append(progress)
        },
      )
      let updates = await recorder.updates

      let first = try #require(updates.first)
      let last = try #require(updates.last)
      #expect(updates.count >= 2)
      #expect(!first.isComplete)
      #expect(first.processedFrameCount > 0)
      #expect(first.processedFrameCount < Int(frameCount))
      #expect(first.totalFrameCount == Int(frameCount))
      #expect(last.isComplete)
      #expect(last.processedFrameCount == Int(frameCount))
      #expect(last.totalFrameCount == Int(frameCount))
      #expect(
        last.snapshot.timelineLayout
          == .staticLinear(
            availableRawSampleCount: Int(frameCount),
            totalRawSampleCount: Int(frameCount),
          ))
      #expect(last.snapshot == result.snapshot)
    }

    @Test
    func `segment extraction reports progress on its concatenated timeline`() async throws {
      let sampleRate: Double = 44100
      let frameCount: AVAudioFrameCount = 44100
      let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
      let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
      buffer.frameLength = frameCount

      if let channelData = unsafe buffer.floatChannelData {
        for frame in 0..<Int(frameCount) {
          unsafe channelData[0][frame] = frame < Int(frameCount / 2) ? 0.25 : 0.75
        }
      }

      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("caf")
      defer { try? FileManager.default.removeItem(at: url) }

      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      try file.write(from: buffer)

      let segments: [ClosedRange<TimeInterval>] = [0.75...1.0, 0.0...0.25]
      let recorder = ProgressRecorder()
      let extractor = OfflineLODExtractor(configuration: .default)
      let progressive = try await extractor.extract(
        from: url,
        segments: segments,
        onProgress: { progress in
          await recorder.append(progress)
        },
      )
      let terminal = try await extractor.extract(from: url, segments: segments)
      let updates = await recorder.updates

      let first = try #require(updates.first)
      let last = try #require(updates.last)
      #expect(updates.count >= 2)
      #expect(!first.isComplete)
      #expect(first.totalFrameCount == 22050)
      #expect(last.isComplete)
      #expect(last.processedFrameCount == 22050)
      #expect(last.totalFrameCount == 22050)
      #expect(
        last.snapshot.timelineLayout
          == .staticLinear(
            availableRawSampleCount: 22050,
            totalRawSampleCount: 22050,
          ))
      #expect(progressive.snapshot == terminal.snapshot)

      for (earlier, later) in zip(updates, updates.dropFirst()) {
        #expect(earlier.processedFrameCount <= later.processedFrameCount)
      }
    }

    @Test
    func `cancelling from progress stops before final delivery`() async throws {
      let sampleRate: Double = 44100
      let frameCount: AVAudioFrameCount = 4096
      let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
      let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
      buffer.frameLength = frameCount

      if let channelData = unsafe buffer.floatChannelData {
        for frame in 0..<Int(frameCount) {
          unsafe channelData[0][frame] = 0.5
        }
      }

      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("caf")
      defer { try? FileManager.default.removeItem(at: url) }

      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      try file.write(from: buffer)

      let recorder = ProgressRecorder()
      let work = Task {
        do {
          let result = try await OfflineLODExtractor(configuration: .default).extract(
            from: url,
            onProgress: { progress in
              await recorder.append(progress)
              if !progress.isComplete {
                unsafe withUnsafeCurrentTask { task in
                  unsafe task?.cancel()
                }
              }
            },
          )
          return CancellationOutcome.completed(result)
        } catch let error as MultiBandLODProcessor.LODGenerationError {
          return CancellationOutcome.failed(error)
        } catch {
          preconditionFailure("Unexpected extraction error: \(error)")
        }
      }

      switch await work.value {
      case .completed:
        Issue.record("Expected extraction cancellation")
      case .failed(.cancelled):
        break
      case .failed(let error):
        Issue.record("Unexpected extraction error: \(error)")
      }
      #expect(await recorder.updates.allSatisfy { !$0.isComplete })
    }

    @Test
    func `extract produces result with correct metadata`() async throws {
      let sampleRate: Double = 44100
      let frameCount: AVAudioFrameCount = 44100  // 1 second
      let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
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

    @Test
    func `extract from segments concatenates correctly`() async throws {
      let sampleRate: Double = 44100
      let frameCount: AVAudioFrameCount = 88200  // 2 seconds
      let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
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

    @Test
    func `channel strategy controls offline channel mixdown`() async throws {
      let sampleRate: Double = 44100
      let frameCount: AVAudioFrameCount = 44100  // 1 second
      let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
      guard let buffer else { return }
      buffer.frameLength = frameCount

      if let channelData = unsafe buffer.floatChannelData {
        let twoPiFrequency = 2.0 * Double.pi * 440.0
        for i in 0..<Int(frameCount) {
          let t = Double(i) / sampleRate
          unsafe channelData[0][i] = Float(sin(twoPiFrequency * t))
          unsafe channelData[1][i] = 0
        }
      }

      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("caf")
      defer { try? FileManager.default.removeItem(at: url) }

      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      try file.write(from: buffer)

      let config = MultiBandLODConfiguration(
        bandCount: 5, lodRatio: 64, sampleRate: Int(sampleRate),
      )
      let extractor = OfflineLODExtractor(configuration: config)

      let leftSnapshot = try await extractor.extract(from: url, channelStrategy: .left).snapshot
      let rightSnapshot = try await extractor.extract(from: url, channelStrategy: .right).snapshot
      let averageSnapshot = try await extractor.extract(from: url, channelStrategy: .average)
        .snapshot
      let weightedLeftSnapshot = try await extractor.extract(
        from: url,
        channelStrategy: .weighted([1, 0]),
      ).snapshot

      let leftEnergy = rmsPeak(leftSnapshot)
      let rightEnergy = rmsPeak(rightSnapshot)
      let averageEnergy = rmsPeak(averageSnapshot)
      let weightedLeftEnergy = rmsPeak(weightedLeftSnapshot)

      #expect(leftEnergy > 0.01)
      #expect(rightEnergy < leftEnergy * 0.1)
      #expect(averageEnergy > leftEnergy * 0.35)
      #expect(averageEnergy < leftEnergy * 0.65)
      #expect(abs(weightedLeftEnergy - leftEnergy) < max(0.01, leftEnergy * 0.1))
    }

    private func rmsPeak(_ snapshot: MultiBandLODSnapshot) -> Float {
      var peak: Float = 0
      guard snapshot.writeIndex > 0 else { return 0 }

      for band in 0..<snapshot.bandCount {
        unsafe snapshot.withContiguousLODChannel(band: band, channel: .rms) { ptr in
          let count = min(snapshot.writeIndex, ptr.count)
          guard count > 0 else { return }
          for index in 0..<count {
            peak = unsafe max(peak, abs(ptr[index]))
          }
        }
      }
      return peak
    }
  }

  private actor ProgressRecorder {
    private var recordedUpdates: [OfflineLODProgress] = []

    var updates: [OfflineLODProgress] {
      recordedUpdates
    }

    func append(_ progress: OfflineLODProgress) {
      recordedUpdates.append(progress)
    }
  }

  private enum CancellationOutcome: Sendable {
    case completed(OfflineLODResult)
    case failed(MultiBandLODProcessor.LODGenerationError)
  }
#endif
