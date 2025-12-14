#if canImport(AVFoundation)
  import AIOEngine
  import Foundation
  import Testing

  @Suite("Frequency Bucketer Tests")
  struct FrequencyBucketerTests {

    // MARK: - Initialization Tests

    @Test("FrequencyBucketer initializes with default configuration")
    func testFrequencyBucketerDefaultInit() {
      let bucketer = FrequencyBucketer()
      #expect(bucketer.currentMode == .mel(bucketCount: 24))
    }

    @Test("FrequencyBucketer initializes with custom configuration")
    func testFrequencyBucketerCustomInit() {
      let bucketer = FrequencyBucketer(mode: .linear(bucketCount: 32), sampleRate: 48000)
      #expect(bucketer.currentMode == .linear(bucketCount: 32))
    }

    // MARK: - MEL Bucketing Tests

    @Test("MEL bucketing produces correct number of buckets")
    func testMELBucketingCount() {
      let bucketer = FrequencyBucketer(mode: .mel(bucketCount: 24))
      let spectrum = Array(repeating: Float(0.5), count: 256)
      let frequencies = (0..<256).map { Float($0) * (22050.0 / 256.0) }

      let buckets = bucketer.bucket(spectrum: spectrum, frequencies: frequencies)
      #expect(buckets.count == 24)
    }

    @Test("MEL bucketing assigns correct IDs")
    func testMELBucketingIDs() {
      let bucketer = FrequencyBucketer(mode: .mel(bucketCount: 16))
      let spectrum = Array(repeating: Float(0.5), count: 128)
      let frequencies = (0..<128).map { Float($0) * (22050.0 / 128.0) }

      let buckets = bucketer.bucket(spectrum: spectrum, frequencies: frequencies)
      for (index, bucket) in buckets.enumerated() {
        #expect(bucket.id == index)
      }
    }

    // MARK: - Logarithmic Bucketing Tests

    @Test("Logarithmic bucketing produces correct number of buckets")
    func testLogarithmicBucketingCount() {
      let bucketer = FrequencyBucketer(mode: .logarithmic(bucketCount: 10))
      let spectrum = Array(repeating: Float(0.5), count: 256)
      let frequencies = (0..<256).map { Float($0) * (22050.0 / 256.0) }

      let buckets = bucketer.bucket(spectrum: spectrum, frequencies: frequencies)
      #expect(buckets.count == 10)
    }

    // MARK: - Linear Bucketing Tests

    @Test("Linear bucketing produces correct number of buckets")
    func testLinearBucketingCount() {
      let bucketer = FrequencyBucketer(mode: .linear(bucketCount: 8))
      let spectrum = Array(repeating: Float(0.5), count: 256)
      let frequencies = (0..<256).map { Float($0) * (22050.0 / 256.0) }

      let buckets = bucketer.bucket(spectrum: spectrum, frequencies: frequencies)
      #expect(buckets.count == 8)
    }

    // MARK: - Standard Bands Tests

    @Test("Standard bands bucketing produces correct number of buckets")
    func testStandardBandsBucketing() {
      let bucketer = FrequencyBucketer(mode: .bands(.musicProduction))
      let spectrum = Array(repeating: Float(0.5), count: 256)
      let frequencies = (0..<256).map { Float($0) * (22050.0 / 256.0) }

      let buckets = bucketer.bucket(spectrum: spectrum, frequencies: frequencies)
      #expect(buckets.count == StandardBands.musicProduction.ranges.count)
    }

    // MARK: - Empty Input Tests

    @Test("Empty spectrum returns empty buckets with decay")
    func testEmptySpectrum() {
      let bucketer = FrequencyBucketer(mode: .mel(bucketCount: 8))

      // First call with non-empty data
      let spectrum = Array(repeating: Float(0.5), count: 64)
      let frequencies = (0..<64).map { Float($0) * (22050.0 / 64.0) }
      _ = bucketer.bucket(spectrum: spectrum, frequencies: frequencies)

      // Second call with empty data
      let emptyBuckets = bucketer.bucket(spectrum: [], frequencies: [])
      #expect(emptyBuckets.count == 8)
    }

    // MARK: - Peak Hold Tests

    @Test("Peak hold values decay over time")
    func testPeakHoldDecay() {
      let bucketer = FrequencyBucketer(mode: .mel(bucketCount: 8))
      let frequencies = (0..<64).map { Float($0) * (22050.0 / 64.0) }

      // First call with high values
      let highSpectrum = Array(repeating: Float(1.0), count: 64)
      let buckets1 = bucketer.bucket(spectrum: highSpectrum, frequencies: frequencies)
      let initialPeak = buckets1.first?.peakHold ?? 0

      // Second call with low values
      let lowSpectrum = Array(repeating: Float(0.1), count: 64)
      let buckets2 = bucketer.bucket(spectrum: lowSpectrum, frequencies: frequencies)
      let decayedPeak = buckets2.first?.peakHold ?? 0

      // Peak should be higher than magnitude due to decay (not instant drop)
      #expect(decayedPeak >= buckets2.first?.magnitude ?? 0)
    }

    @Test("Reset peak hold clears all values")
    func testResetPeakHold() {
      let bucketer = FrequencyBucketer(mode: .mel(bucketCount: 8))
      let frequencies = (0..<64).map { Float($0) * (22050.0 / 64.0) }

      // First call with high values
      let highSpectrum = Array(repeating: Float(1.0), count: 64)
      _ = bucketer.bucket(spectrum: highSpectrum, frequencies: frequencies)

      // Reset peak hold
      bucketer.resetPeakHold()

      // Next call should start fresh
      let lowSpectrum = Array(repeating: Float(0.1), count: 64)
      let buckets = bucketer.bucket(spectrum: lowSpectrum, frequencies: frequencies)

      // Peak hold should equal magnitude (no prior peak to decay from)
      for bucket in buckets {
        #expect(bucket.peakHold <= bucket.magnitude + 0.001)  // Small tolerance for float comparison
      }
    }

    // MARK: - Mode Update Tests

    @Test("Mode can be updated")
    func testModeUpdate() {
      let bucketer = FrequencyBucketer(mode: .mel(bucketCount: 24))
      #expect(bucketer.currentMode == .mel(bucketCount: 24))

      bucketer.updateMode(.linear(bucketCount: 16))
      #expect(bucketer.currentMode == .linear(bucketCount: 16))

      let spectrum = Array(repeating: Float(0.5), count: 128)
      let frequencies = (0..<128).map { Float($0) * (22050.0 / 128.0) }
      let buckets = bucketer.bucket(spectrum: spectrum, frequencies: frequencies)
      #expect(buckets.count == 16)
    }

    @Test("Same mode update is no-op")
    func testSameModeUpdate() {
      let bucketer = FrequencyBucketer(mode: .mel(bucketCount: 24))
      let frequencies = (0..<64).map { Float($0) * (22050.0 / 64.0) }

      // Build up peak hold
      let highSpectrum = Array(repeating: Float(1.0), count: 64)
      _ = bucketer.bucket(spectrum: highSpectrum, frequencies: frequencies)

      // Update to same mode
      bucketer.updateMode(.mel(bucketCount: 24))

      // Peak hold should NOT be reset
      let lowSpectrum = Array(repeating: Float(0.1), count: 64)
      let buckets = bucketer.bucket(spectrum: lowSpectrum, frequencies: frequencies)

      // Peak hold should still be higher than magnitude
      let bucket = buckets.first!
      #expect(bucket.peakHold > bucket.magnitude)
    }

    // MARK: - Frequency Range Tests

    @Test("Bucket frequency ranges are ordered")
    func testBucketFrequencyRangesOrdered() {
      let bucketer = FrequencyBucketer(mode: .mel(bucketCount: 16))
      let spectrum = Array(repeating: Float(0.5), count: 128)
      let frequencies = (0..<128).map { Float($0) * (22050.0 / 128.0) }

      let buckets = bucketer.bucket(spectrum: spectrum, frequencies: frequencies)

      for i in 1..<buckets.count {
        #expect(buckets[i].lowFrequency >= buckets[i - 1].highFrequency)
      }
    }

    @Test("Bucket frequency ranges are non-negative")
    func testBucketFrequencyRangesNonNegative() {
      let bucketer = FrequencyBucketer(mode: .logarithmic(bucketCount: 10))
      let spectrum = Array(repeating: Float(0.5), count: 128)
      let frequencies = (0..<128).map { Float($0) * (22050.0 / 128.0) }

      let buckets = bucketer.bucket(spectrum: spectrum, frequencies: frequencies)

      for bucket in buckets {
        #expect(bucket.lowFrequency >= 0)
        #expect(bucket.highFrequency > bucket.lowFrequency)
      }
    }
  }

#endif
