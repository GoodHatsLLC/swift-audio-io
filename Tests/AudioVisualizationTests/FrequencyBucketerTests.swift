#if canImport(AVFoundation)
  import AIOEngine
  import Foundation
  import Testing

  @Suite("Frequency Bucketer Tests")
  struct FrequencyBucketerTests {
    private func linearFrequencies(count: Int, min: Float = 20, max: Float = 20_000) -> [Float] {
      guard count > 1 else { return [min] }
      let span = max - min
      return (0..<count).map { index in
        min + (Float(index) / Float(count - 1)) * span
      }
    }

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

    // MARK: - Weighting Tests

    @Test("A-weighting emphasizes midrange frequencies")
    func testAWeightingEmphasis() {
      let bucketer = FrequencyBucketer(
        mode: .bands(.threeBand),
        sampleRate: 44_100,
        peakHoldDecayRate: 0,
        weighting: .aWeighting
      )
      let spectrum = Array(repeating: Float(1.0), count: 512)
      let frequencies = linearFrequencies(count: spectrum.count)

      let buckets = bucketer.bucket(spectrum: spectrum, frequencies: frequencies)
      #expect(buckets.count == 3)

      let low = buckets[0].magnitude
      let mid = buckets[1].magnitude
      let high = buckets[2].magnitude

      #expect(mid > low)
      #expect(mid > high)
    }

    @Test("No weighting keeps magnitudes uniform for flat spectrum")
    func testNoWeightingUniform() {
      let bucketer = FrequencyBucketer(
        mode: .bands(.threeBand),
        sampleRate: 44_100,
        peakHoldDecayRate: 0,
        weighting: .none
      )
      let spectrum = Array(repeating: Float(1.0), count: 512)
      let frequencies = linearFrequencies(count: spectrum.count)

      let buckets = bucketer.bucket(spectrum: spectrum, frequencies: frequencies)
      let magnitudes = buckets.map(\.magnitude)
      let minValue = magnitudes.min() ?? 0
      let maxValue = magnitudes.max() ?? 0
      #expect(abs(maxValue - minValue) < 0.001)
    }

    @Test("Updating weighting recomputes bucket magnitudes")
    func testWeightingUpdate() {
      let bucketer = FrequencyBucketer(
        mode: .bands(.threeBand),
        sampleRate: 44_100,
        peakHoldDecayRate: 0,
        weighting: .none
      )
      let spectrum = Array(repeating: Float(1.0), count: 512)
      let frequencies = linearFrequencies(count: spectrum.count)

      let unweighted = bucketer.bucket(spectrum: spectrum, frequencies: frequencies)
      bucketer.updateWeighting(.aWeighting)
      let weighted = bucketer.bucket(spectrum: spectrum, frequencies: frequencies)

      #expect(weighted[0].magnitude < unweighted[0].magnitude)
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
      #expect(initialPeak >= decayedPeak)
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
        // Small tolerance for float comparison
        #expect(bucket.peakHold <= bucket.magnitude + 0.001)
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

      // Peak hold should still be higher than magnitude for at least one non-empty bucket.
      let maxMagnitude = buckets.map(\.magnitude).max() ?? 0
      let maxPeakHold = buckets.map(\.peakHold).max() ?? 0
      #expect(maxPeakHold > maxMagnitude)
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
