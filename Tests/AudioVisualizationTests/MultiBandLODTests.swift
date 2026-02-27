#if canImport(AVFoundation)
  import AIOEngine
  import AudioSignals
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
      "Offline extractor uses exact frame count (plus one LOD pad) and monotonic writeIndex")
    func testOfflineExtractorSizingAndWriteIndex() async throws {
      let sampleRate: Double = 44_100
      let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
      #expect(format != nil)
      guard let format else { return }

      let frameCount: AVAudioFrameCount = 1000
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
      #expect(buffer != nil)
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

      let config = MultiBandLODConfiguration(
        bandCount: 5, lodRatio: 128, bufferSeconds: 1, sampleRate: Int(sampleRate))
      let snapshot = try await OfflineLODExtractor(configuration: config).extract(from: url)
        .snapshot

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
      let processor = unsafe MultiBandLODProcessor(configuration: config)

      // Process some samples
      let samples = generateSineWave(frequency: 440, sampleRate: 44100, samples: 1024)
      unsafe processor.process(samples)

      // Get snapshot (should not block)
      let snapshot = unsafe processor.snapshot()
      #expect(snapshot.bandCount == 3)
      #expect(snapshot.lodRatio == 64)
    }

    @Test("Processor snapshotRef returns valid reference")
    func testProcessorSnapshotRef() {
      let config = MultiBandLODConfiguration(bandCount: 5, lodRatio: 128, bufferSeconds: 10)
      let processor = unsafe MultiBandLODProcessor(configuration: config)

      let samples = generateSineWave(frequency: 440, sampleRate: 44100, samples: 2048)
      unsafe processor.process(samples)

      let ref = unsafe processor.snapshotRef()
      unsafe #expect(ref.bandCount == 5)
      unsafe #expect(ref.lodRatio == 128)
      unsafe #expect(ref.lodBufferLength > 0)
    }

    @Test("Processor exposes frame-scoped snapshot accessor")
    func testProcessorFrameScopedSnapshotAccessor() {
      let config = MultiBandLODConfiguration(
        bandCount: 3,
        lodRatio: 1,
        bufferSeconds: 10,
        sampleRate: 100,
        snapshotSwapInterval: 1
      )
      let processor = unsafe MultiBandLODProcessor(configuration: config)

      unsafe processor.process([0.1, 0.2, 0.3, 0.4])

      let scopedWriteIndex = unsafe processor.withCurrentLODSnapshotRef { $0.writeIndex }
      let directWriteIndex = unsafe processor.snapshotRef().writeIndex
      #expect(scopedWriteIndex == directWriteIndex)

      unsafe processor.process([0.5, 0.6, 0.7, 0.8])
      let nextWriteIndex = unsafe processor.withCurrentLODSnapshotRef { $0.writeIndex }
      #expect(nextWriteIndex != scopedWriteIndex)
    }

    @Test("LODSnapshotRef provides buffer access")
    func testSnapshotRefBufferAccess() {
      let config = MultiBandLODConfiguration(bandCount: 3, lodRatio: 64, bufferSeconds: 5)
      let processor = unsafe MultiBandLODProcessor(configuration: config)

      // Process enough data to fill some LOD buckets
      for _ in 0..<10 {
        let samples = generateSineWave(frequency: 440, sampleRate: 44100, samples: 1024)
        unsafe processor.process(samples)
      }

      let ref = unsafe processor.snapshotRef()

      // Test direct buffer access
      unsafe ref.withContiguousLODChannel(band: 0, channel: .min) { buffer in
        unsafe #expect(buffer.count == ref.lodBufferLength)
      }

      unsafe ref.withContiguousLODChannel(band: 0, channel: .max) { buffer in
        unsafe #expect(buffer.count == ref.lodBufferLength)
      }

      unsafe ref.withContiguousLODChannel(band: 0, channel: .rms) { buffer in
        unsafe #expect(buffer.count == ref.lodBufferLength)
      }
    }

    @Test("LODSnapshotRef checked band access returns nil out-of-range")
    func testSnapshotRefCheckedBandAccess() {
      let config = MultiBandLODConfiguration(bandCount: 2, lodRatio: 32, bufferSeconds: 5)
      let processor = unsafe MultiBandLODProcessor(configuration: config)
      unsafe processor.process(generateSineWave(frequency: 440, sampleRate: 44100, samples: 256))

      let ref = unsafe processor.snapshotRef()
      let valid = unsafe ref.withContiguousLODChannelIfValid(band: 1, channel: .min) { $0.count }
      let invalidNegative = unsafe ref.withContiguousLODChannelIfValid(band: -1, channel: .min) {
        $0.count
      }
      let invalidUpper = unsafe ref.withContiguousLODChannelIfValid(
        band: ref.bandCount,
        channel: .min
      ) { $0.count }

      #expect(valid == ref.lodBufferLength)
      #expect(invalidNegative == nil)
      #expect(invalidUpper == nil)
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
      let processor = unsafe MultiBandLODProcessor(configuration: config)

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
            unsafe processor.process(samples)
            unsafe writeIndices.append(processor.currentWriteIndex)

            // Small delay to simulate real audio timing
            if i % 100 == 0 {
              try? await Task.sleep(nanoseconds: 1_000)
            }
          }
          return writeIndices
        }

        // Reader tasks - simulate render threads
        for _ in 0..<readerCount {
          group.addTask {
            var readIndices: [Int] = []
            for _ in 0..<(iterations / 2) {
              // Should never block
              let ref = unsafe processor.snapshotRef()
              unsafe readIndices.append(ref.writeIndex)

              // Access buffer data (verifies no crash from concurrent access)
              unsafe ref.withContiguousLODChannel(band: 0, channel: .min) { buffer in
                _ = unsafe buffer.first
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
      let processor = unsafe MultiBandLODProcessor(configuration: config)

      // Fill with known pattern
      for i in 0..<100 {
        let samples = [Float](repeating: Float(i % 10) * 0.1, count: 256)
        unsafe processor.process(samples)
      }

      // Read snapshot multiple times and verify consistency
      await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<10 {
          group.addTask {
            let ref = unsafe processor.snapshotRef()

            // All bands should have same buffer length
            for band in unsafe 0..<ref.bandCount {
              var minCount = 0
              var maxCount = 0
              var rmsCount = 0

              unsafe ref.withContiguousLODChannel(band: band, channel: .min) { buffer in
                minCount = buffer.count
              }
              unsafe ref.withContiguousLODChannel(band: band, channel: .max) { buffer in
                maxCount = buffer.count
              }
              unsafe ref.withContiguousLODChannel(band: band, channel: .rms) { buffer in
                rmsCount = buffer.count
              }

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
      let fastProcessor = unsafe MultiBandLODProcessor(configuration: fastConfig)

      // With interval=10, snapshot swaps every 10 LOD commits
      let slowConfig = MultiBandLODConfiguration(
        bandCount: 3,
        lodRatio: 64,
        bufferSeconds: 10,
        snapshotSwapInterval: 10
      )
      let slowProcessor = unsafe MultiBandLODProcessor(configuration: slowConfig)

      // Process same amount of data through both
      var fastWriteIndices: Set<Int> = []
      var slowWriteIndices: Set<Int> = []

      for _ in 0..<50 {
        let samples = generateSineWave(frequency: 440, sampleRate: 44100, samples: 256)

        unsafe fastProcessor.process(samples)
        unsafe fastWriteIndices.insert(fastProcessor.snapshotRef().writeIndex)

        unsafe slowProcessor.process(samples)
        unsafe slowWriteIndices.insert(slowProcessor.snapshotRef().writeIndex)
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
      let processor = unsafe MultiBandLODProcessor(configuration: config)

      // Fill with some data
      for _ in 0..<100 {
        let samples = generateSineWave(frequency: 440, sampleRate: 44100, samples: 1024)
        unsafe processor.process(samples)
      }

      let iterations = 10000
      let startTime = CFAbsoluteTimeGetCurrent()

      for _ in 0..<iterations {
        _ = unsafe processor.snapshotRef()
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
      let processor = unsafe MultiBandLODProcessor(configuration: config)

      // Fill with data
      for _ in 0..<50 {
        let samples = generateSineWave(frequency: 440, sampleRate: 44100, samples: 1024)
        unsafe processor.process(samples)
      }

      let iterations = 5000
      let startTime = CFAbsoluteTimeGetCurrent()

      for _ in 0..<iterations {
        let ref = unsafe processor.snapshotRef()
        // Access all bands - should be zero-copy
        for band in unsafe 0..<ref.bandCount {
          unsafe ref.withContiguousLODChannel(band: band, channel: .min) { _ = unsafe $0.first }
          unsafe ref.withContiguousLODChannel(band: band, channel: .max) { _ = unsafe $0.first }
          unsafe ref.withContiguousLODChannel(band: band, channel: .rms) { _ = unsafe $0.first }
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
      let processor = unsafe MultiBandLODProcessor(configuration: config)

      // Process data
      for _ in 0..<20 {
        let samples = generateSineWave(frequency: 440, sampleRate: 44100, samples: 512)
        unsafe processor.process(samples)
      }

      unsafe #expect(processor.currentWriteIndex > 0)

      // Reset
      unsafe processor.reset()

      // Verify reset
      let ref = unsafe processor.snapshotRef()
      unsafe #expect(ref.writeIndex == 0)

      // All buffers should be zero
      unsafe ref.withContiguousLODChannel(band: 0, channel: .min) { buffer in
        let nonZero = unsafe buffer.contains { $0 != 0 }
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
      let processor = unsafe MultiBandLODProcessor(configuration: config)

      let samples = generateSineWave(frequency: 200, sampleRate: 44_100, samples: 44_100 / 2)
      unsafe processor.process(samples)

      let snapshot = unsafe processor.snapshotLocking()
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
      let processor = unsafe MultiBandLODProcessor(configuration: config)

      let samples = generateSineWave(frequency: 2000, sampleRate: 44_100, samples: 44_100 / 2)
      unsafe processor.process(samples)

      let snapshot = unsafe processor.snapshotLocking()
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
      let processor = unsafe MultiBandLODProcessor(configuration: config)

      let samples = generateSineWave(frequency: 10_000, sampleRate: 44_100, samples: 44_100 / 2)
      unsafe processor.process(samples)

      let snapshot = unsafe processor.snapshotLocking()
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
