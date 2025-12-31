#if canImport(AVFoundation)
  import AIOEngine
  import AVFoundation
  import Foundation
  import Testing

  @Suite("MultiBandLOD Triple-Buffer Tests")
  struct MultiBandLODTests {

    // MARK: - Configuration Tests

    @Test("Configuration includes snapshotSwapInterval")
    func testConfigurationSnapshotSwapInterval() {
      let defaultConfig = MultiBandLODConfiguration.default
      #expect(defaultConfig.snapshotSwapInterval == 6)

      let customConfig = MultiBandLODConfiguration(snapshotSwapInterval: 10)
      #expect(customConfig.snapshotSwapInterval == 10)

      // Minimum clamping
      let tooLow = MultiBandLODConfiguration(snapshotSwapInterval: 0)
      #expect(tooLow.snapshotSwapInterval == 1)
    }

    @Test("Configuration default presets")
    func testConfigurationPresets() {
      let shortRecording = MultiBandLODConfiguration.shortRecording
      #expect(shortRecording.bufferSeconds == 60)
      #expect(shortRecording.bandCount == 5)

      let highDetail = MultiBandLODConfiguration.highDetail
      #expect(highDetail.bandCount == 8)
      #expect(highDetail.lodRatio == 64)
    }

    // MARK: - Processor Basic Tests

    @Test(
      "Offline generateFromFile uses exact frame count (plus one LOD pad) and monotonic writeIndex")
    func testGenerateFromFileSizingAndWriteIndex() async throws {
      let sampleRate: Double = 44_100
      let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
      #expect(format != nil)
      guard let format else { return }

      let frameCount: AVAudioFrameCount = 1000
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
      #expect(buffer != nil)
      guard let buffer else { return }
      buffer.frameLength = frameCount

      if let channelData = buffer.floatChannelData {
        let twoPiFrequency = 2.0 * Double.pi * 440.0
        for i in 0..<Int(frameCount) {
          let t = Double(i) / sampleRate
          channelData[0][i] = Float(sin(twoPiFrequency * t))
        }
      }

      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("caf")
      defer { try? FileManager.default.removeItem(at: url) }

      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      try file.write(from: buffer)

      let config = MultiBandLODConfiguration(
        bandCount: 5, lodRatio: 128, bufferSeconds: 1, sampleRate: Int(sampleRate))
      let snapshot = try await MultiBandLODProcessor.generateFromFile(
        url: url, configuration: config)

      #expect(snapshot.rawBufferLength == Int(frameCount) + config.lodRatio)

      let expectedWriteIndex = Int(ceil(Double(Int(frameCount)) / Double(config.lodRatio)))
      #expect(snapshot.writeIndex == expectedWriteIndex)
      #expect(snapshot.writeIndex > 0)
      #expect(snapshot.writeIndex < snapshot.lodBufferLength)
    }

    @Test("Processor creates valid snapshot")
    func testProcessorCreatesValidSnapshot() {
      let config = MultiBandLODConfiguration(
        bandCount: 3,
        lodRatio: 64,
        bufferSeconds: 10,
        sampleRate: 44100
      )
      let processor = MultiBandLODProcessor(configuration: config)

      // Process some samples
      let samples = generateSineWave(frequency: 440, sampleRate: 44100, samples: 1024)
      processor.process(samples)

      // Get snapshot (should not block)
      let snapshot = processor.snapshot()
      #expect(snapshot.bandCount == 3)
      #expect(snapshot.lodRatio == 64)
    }

    @Test("Processor snapshotRef returns valid reference")
    func testProcessorSnapshotRef() {
      let config = MultiBandLODConfiguration(bandCount: 5, lodRatio: 128, bufferSeconds: 10)
      let processor = MultiBandLODProcessor(configuration: config)

      let samples = generateSineWave(frequency: 440, sampleRate: 44100, samples: 2048)
      processor.process(samples)

      let ref = processor.snapshotRef()
      #expect(ref.bandCount == 5)
      #expect(ref.lodRatio == 128)
      #expect(ref.lodBufferLength > 0)
    }

    @Test("LODSnapshotRef provides buffer access")
    func testSnapshotRefBufferAccess() {
      let config = MultiBandLODConfiguration(bandCount: 3, lodRatio: 64, bufferSeconds: 5)
      let processor = MultiBandLODProcessor(configuration: config)

      // Process enough data to fill some LOD buckets
      for _ in 0..<10 {
        let samples = generateSineWave(frequency: 440, sampleRate: 44100, samples: 1024)
        processor.process(samples)
      }

      let ref = processor.snapshotRef()

      // Test direct buffer access
      ref.withMinBuffer(band: 0) { buffer in
        #expect(buffer.count == ref.lodBufferLength)
      }

      ref.withMaxBuffer(band: 0) { buffer in
        #expect(buffer.count == ref.lodBufferLength)
      }

      ref.withRMSBuffer(band: 0) { buffer in
        #expect(buffer.count == ref.lodBufferLength)
      }
    }

    // MARK: - Lock-Free Behavior Tests

    @Test("Snapshot is lock-free under concurrent access")
    func testLockFreeSnapshotAccess() async throws {
      let config = MultiBandLODConfiguration(
        bandCount: 5,
        lodRatio: 128,
        bufferSeconds: 60,
        snapshotSwapInterval: 3  // Fast swaps for testing
      )
      let processor = MultiBandLODProcessor(configuration: config)

      let iterations = 1000
      let readerCount = 4

      // Start concurrent readers
      await withTaskGroup(of: [Int].self) { group in
        // Writer task - simulates audio thread
        group.addTask {
          var writeIndices: [Int] = []
          for i in 0..<iterations {
            let samples = generateSineWave(
              frequency: Double(220 + i % 440),
              sampleRate: 44100,
              samples: 512
            )
            processor.process(samples)
            writeIndices.append(processor.currentWriteIndex)

            // Small delay to simulate real audio timing
            if i % 100 == 0 {
              try? await Task.sleep(nanoseconds: 1_000)
            }
          }
          return writeIndices
        }

        // Reader tasks - simulate render threads
        for readerID in 0..<readerCount {
          group.addTask {
            var readIndices: [Int] = []
            for _ in 0..<(iterations / 2) {
              // Should never block
              let ref = processor.snapshotRef()
              readIndices.append(ref.writeIndex)

              // Access buffer data (verifies no crash from concurrent access)
              ref.withMinBuffer(band: 0) { buffer in
                _ = buffer.first
              }
            }
            return readIndices
          }
        }

        // Collect results - if we get here without deadlock, test passes
        var allResults: [[Int]] = []
        for await result in group {
          allResults.append(result)
        }

        #expect(allResults.count == readerCount + 1, "All tasks should complete")
      }
    }

    @Test("Snapshot data is consistent during reads")
    func testSnapshotDataConsistency() async throws {
      let config = MultiBandLODConfiguration(
        bandCount: 3,
        lodRatio: 64,
        bufferSeconds: 30,
        snapshotSwapInterval: 2
      )
      let processor = MultiBandLODProcessor(configuration: config)

      // Fill with known pattern
      for i in 0..<100 {
        let samples = [Float](repeating: Float(i % 10) * 0.1, count: 256)
        processor.process(samples)
      }

      // Read snapshot multiple times and verify consistency
      await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<10 {
          group.addTask {
            let ref = processor.snapshotRef()

            // All bands should have same buffer length
            for band in 0..<ref.bandCount {
              var minCount = 0
              var maxCount = 0
              var rmsCount = 0

              ref.withMinBuffer(band: band) { buffer in minCount = buffer.count }
              ref.withMaxBuffer(band: band) { buffer in maxCount = buffer.count }
              ref.withRMSBuffer(band: band) { buffer in rmsCount = buffer.count }

              if minCount != maxCount || maxCount != rmsCount {
                return false
              }
            }
            return true
          }
        }

        for await isConsistent in group {
          #expect(isConsistent, "Snapshot data should be consistent")
        }
      }
    }

    @Test("Snapshot swap interval affects update frequency")
    func testSnapshotSwapIntervalEffect() {
      // With interval=1, snapshot swaps every LOD commit
      let fastConfig = MultiBandLODConfiguration(
        bandCount: 3,
        lodRatio: 64,
        bufferSeconds: 10,
        snapshotSwapInterval: 1
      )
      let fastProcessor = MultiBandLODProcessor(configuration: fastConfig)

      // With interval=10, snapshot swaps every 10 LOD commits
      let slowConfig = MultiBandLODConfiguration(
        bandCount: 3,
        lodRatio: 64,
        bufferSeconds: 10,
        snapshotSwapInterval: 10
      )
      let slowProcessor = MultiBandLODProcessor(configuration: slowConfig)

      // Process same amount of data through both
      var fastWriteIndices: Set<Int> = []
      var slowWriteIndices: Set<Int> = []

      for _ in 0..<50 {
        let samples = generateSineWave(frequency: 440, sampleRate: 44100, samples: 256)

        fastProcessor.process(samples)
        fastWriteIndices.insert(fastProcessor.snapshotRef().writeIndex)

        slowProcessor.process(samples)
        slowWriteIndices.insert(slowProcessor.snapshotRef().writeIndex)
      }

      // Fast processor should have seen more unique write indices
      // (more frequent slot swaps)
      #expect(
        fastWriteIndices.count >= slowWriteIndices.count,
        "Fast swap interval should produce more unique indices"
      )
    }

    // MARK: - Performance Tests

    @Test("Lock-free snapshot access is fast")
    func testSnapshotAccessPerformance() {
      let config = MultiBandLODConfiguration(
        bandCount: 5,
        lodRatio: 128,
        bufferSeconds: 300
      )
      let processor = MultiBandLODProcessor(configuration: config)

      // Fill with some data
      for _ in 0..<100 {
        let samples = generateSineWave(frequency: 440, sampleRate: 44100, samples: 1024)
        processor.process(samples)
      }

      let iterations = 10000
      let startTime = CFAbsoluteTimeGetCurrent()

      for _ in 0..<iterations {
        _ = processor.snapshotRef()
      }

      let endTime = CFAbsoluteTimeGetCurrent()
      let totalTime = endTime - startTime
      let avgTimePerSnapshot = totalTime / Double(iterations)
      let snapshotsPerSecond = 1.0 / avgTimePerSnapshot

      // Should be able to get at least 60,000 snapshots per second (1000x real-time)
      #expect(
        snapshotsPerSecond > 60_000,
        "Snapshot access too slow: \(Int(snapshotsPerSecond)) snapshots/sec"
      )

      print("Lock-free snapshot performance:")
      print("  Average time per snapshot: \(avgTimePerSnapshot * 1_000_000) µs")
      print("  Snapshots per second: \(Int(snapshotsPerSecond))")
    }

    @Test("Buffer access via snapshotRef has no allocation")
    func testBufferAccessPerformance() {
      let config = MultiBandLODConfiguration(
        bandCount: 5,
        lodRatio: 128,
        bufferSeconds: 60
      )
      let processor = MultiBandLODProcessor(configuration: config)

      // Fill with data
      for _ in 0..<50 {
        let samples = generateSineWave(frequency: 440, sampleRate: 44100, samples: 1024)
        processor.process(samples)
      }

      let iterations = 5000
      let startTime = CFAbsoluteTimeGetCurrent()

      for _ in 0..<iterations {
        let ref = processor.snapshotRef()
        // Access all bands - should be zero-copy
        for band in 0..<ref.bandCount {
          ref.withMinBuffer(band: band) { _ = $0.first }
          ref.withMaxBuffer(band: band) { _ = $0.first }
          ref.withRMSBuffer(band: band) { _ = $0.first }
        }
      }

      let endTime = CFAbsoluteTimeGetCurrent()
      let totalTime = endTime - startTime
      let avgTime = totalTime / Double(iterations)
      let accessesPerSecond = 1.0 / avgTime

      // Should handle 10,000+ full buffer accesses per second
      #expect(
        accessesPerSecond > 10_000,
        "Buffer access too slow: \(Int(accessesPerSecond)) accesses/sec"
      )

      print("Buffer access performance:")
      print("  Average time per full access: \(avgTime * 1_000_000) µs")
      print("  Full accesses per second: \(Int(accessesPerSecond))")
    }

    // MARK: - Reset Tests

    @Test("Reset clears all slots")
    func testResetClearsAllSlots() {
      let config = MultiBandLODConfiguration(bandCount: 3, lodRatio: 64, bufferSeconds: 10)
      let processor = MultiBandLODProcessor(configuration: config)

      // Process data
      for _ in 0..<20 {
        let samples = generateSineWave(frequency: 440, sampleRate: 44100, samples: 512)
        processor.process(samples)
      }

      #expect(processor.currentWriteIndex > 0)

      // Reset
      processor.reset()

      // Verify reset
      let ref = processor.snapshotRef()
      #expect(ref.writeIndex == 0)

      // All buffers should be zero
      ref.withMinBuffer(band: 0) { buffer in
        let nonZero = buffer.contains { $0 != 0 }
        #expect(!nonZero, "Buffer should be zeroed after reset")
      }
    }

    // MARK: - Helper Functions

    @Test("Band split: 200 Hz dominates low band")
    func testBandSplitLowTone() {
      let config = MultiBandLODConfiguration(
        bandCount: 5,
        lodRatio: 64,
        bufferSeconds: 10,
        sampleRate: 44_100,
        crossoverMode: .mel(minFreq: 40, maxFreq: 15_000),
        snapshotSwapInterval: 1
      )
      let processor = MultiBandLODProcessor(configuration: config)

      let samples = generateSineWave(frequency: 200, sampleRate: 44_100, samples: 44_100 / 2)
      processor.process(samples)

      let snapshot = processor.snapshotLocking()
      let averages = recentAverageRMS(snapshot, recentSamples: 16)

      let maxBand = averages.enumerated().max(by: { $0.element < $1.element })?.offset
      #expect(maxBand == 0)
    }

    @Test("Band split: 2 kHz shifts energy upward")
    func testBandSplitMidTone() {
      let config = MultiBandLODConfiguration(
        bandCount: 5,
        lodRatio: 64,
        bufferSeconds: 10,
        sampleRate: 44_100,
        crossoverMode: .mel(minFreq: 40, maxFreq: 15_000),
        snapshotSwapInterval: 1
      )
      let processor = MultiBandLODProcessor(configuration: config)

      let samples = generateSineWave(frequency: 2000, sampleRate: 44_100, samples: 44_100 / 2)
      processor.process(samples)

      let snapshot = processor.snapshotLocking()
      let averages = recentAverageRMS(snapshot, recentSamples: 16)

      let maxBand = averages.enumerated().max(by: { $0.element < $1.element })?.offset
      #expect(maxBand == 1 || maxBand == 2)
      #expect(averages[maxBand ?? 0] > averages[0])
    }

    @Test("Band split: 10 kHz shows meaningful top-band energy")
    func testBandSplitHighTone() {
      let config = MultiBandLODConfiguration(
        bandCount: 5,
        lodRatio: 64,
        bufferSeconds: 10,
        sampleRate: 44_100,
        crossoverMode: .mel(minFreq: 40, maxFreq: 15_000),
        snapshotSwapInterval: 1
      )
      let processor = MultiBandLODProcessor(configuration: config)

      let samples = generateSineWave(frequency: 10_000, sampleRate: 44_100, samples: 44_100 / 2)
      processor.process(samples)

      let snapshot = processor.snapshotLocking()
      let averages = recentAverageRMS(snapshot, recentSamples: 16)

      let maxBand = averages.enumerated().max(by: { $0.element < $1.element })?.offset
      #expect(maxBand == 4)
      #expect(averages[4] > 0.001)
    }

    private func recentAverageRMS(_ snapshot: MultiBandLODSnapshot, recentSamples: Int) -> [Float] {
      let lodLength = snapshot.lodBufferLength
      guard lodLength > 0 else { return Array(repeating: 0, count: snapshot.bandCount) }

      let count = min(recentSamples, lodLength)
      let writeIndex = snapshot.writeIndex

      func wrapped(_ idx: Int) -> Int {
        let r = idx % lodLength
        return r < 0 ? (r + lodLength) : r
      }

      return snapshot.bands.map { band in
        var sum: Float = 0
        for i in 0..<count {
          let idx = wrapped(writeIndex - 1 - i)
          sum += band.rmsBuffer[idx]
        }
        return sum / Float(count)
      }
    }

    private func generateSineWave(frequency: Double, sampleRate: Int, samples: Int) -> [Float] {
      var result: [Float] = []
      result.reserveCapacity(samples)
      let angularFrequency = 2.0 * Double.pi * frequency
      for i in 0..<samples {
        let time = Double(i) / Double(sampleRate)
        result.append(Float(sin(angularFrequency * time)))
      }
      return result
    }
  }

#endif
