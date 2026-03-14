// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOEngine
  import AudioSignals
  import Foundation
  import Testing

  struct VisualizationTypesTests {
    // MARK: - TimeDomainData Tests

    @Test
    func `TimeDomainData initialization with default values`() {
      let data = TimeDomainData()
      #expect(data.samples.isEmpty)
      #expect(data.peaks.isEmpty)
      #expect(data.rmsLevel == 0)
      #expect(data.level == 0)
    }

    @Test
    func `TimeDomainData initialization with values`() {
      let samples: [Float] = [0.1, 0.5, 0.8, 0.3]
      let peaks: [Float] = [0.2, 0.6, 0.9, 0.4]
      let data = TimeDomainData(samples: samples, peaks: peaks, rmsLevel: 0.5, level: 0.9)

      #expect(data.samples == samples)
      #expect(data.peaks == peaks)
      #expect(data.rmsLevel == 0.5)
      #expect(data.level == 0.9)
    }

    @Test
    func `TimeDomainData empty static property`() {
      let empty = TimeDomainData.empty
      #expect(empty.samples.isEmpty)
      #expect(empty.peaks.isEmpty)
      #expect(empty.rmsLevel == 0)
      #expect(empty.level == 0)
    }

    // MARK: - FrequencyDomainData Tests

    @Test
    func `FrequencyDomainData initialization with default values`() {
      let data = FrequencyDomainData()
      #expect(data.buckets.isEmpty)
      #expect(data.rawSpectrum.isEmpty)
      #expect(data.frequencies.isEmpty)
      #expect(data.peakFrequency == 0)
      #expect(data.spectralCentroid == 0)
    }

    @Test
    func `FrequencyDomainData empty static property`() {
      let empty = FrequencyDomainData.empty
      #expect(empty.buckets.isEmpty)
      #expect(empty.rawSpectrum.isEmpty)
      #expect(empty.peakFrequency == 0)
    }

    // MARK: - FrequencyBucket Tests

    @Test
    func `FrequencyBucket initialization`() {
      let bucket = FrequencyBucket(
        id: 0,
        lowFrequency: 100,
        highFrequency: 200,
        magnitude: 0.5,
        peakHold: 0.8,
      )

      #expect(bucket.id == 0)
      #expect(bucket.lowFrequency == 100)
      #expect(bucket.highFrequency == 200)
      #expect(bucket.magnitude == 0.5)
      #expect(bucket.peakHold == 0.8)
    }

    @Test
    func `FrequencyBucket centerFrequency calculation`() {
      let bucket = FrequencyBucket(id: 0, lowFrequency: 100, highFrequency: 200)
      #expect(bucket.centerFrequency == 150)
    }

    @Test
    func `FrequencyBucket label formatting`() {
      let lowBucket = FrequencyBucket(id: 0, lowFrequency: 100, highFrequency: 200)
      #expect(lowBucket.label == "150")  // Center frequency < 1000

      let highBucket = FrequencyBucket(id: 1, lowFrequency: 1000, highFrequency: 2000)
      #expect(highBucket.label == "1.5k")  // Center frequency >= 1000
    }

    // MARK: - BeatInfo Tests

    @Test
    func `BeatInfo initialization with default values`() {
      let info = BeatInfo()
      #expect(!info.beatDetected)
      #expect(info.energy == 0)
      #expect(info.timeSinceLastBeat == .infinity)
      #expect(info.estimatedTempo == 0)
    }

    @Test
    func `BeatInfo with detected beat`() {
      let info = BeatInfo(
        beatDetected: true,
        energy: 0.8,
        timeSinceLastBeat: 0.5,
        estimatedTempo: 120,
      )

      #expect(info.beatDetected)
      #expect(info.energy == 0.8)
      #expect(info.timeSinceLastBeat == 0.5)
      #expect(info.estimatedTempo == 120)
    }

    @Test
    func `BeatInfo empty static property`() {
      let empty = BeatInfo.empty
      #expect(!empty.beatDetected)
      #expect(empty.energy == 0)
    }

    // MARK: - FrequencyBucketMode Tests

    @Test
    func `FrequencyBucketMode bucket count`() {
      #expect(FrequencyBucketMode.mel(bucketCount: 24).bucketCount == 24)
      #expect(FrequencyBucketMode.logarithmic(bucketCount: 32).bucketCount == 32)
      #expect(FrequencyBucketMode.linear(bucketCount: 16).bucketCount == 16)
      #expect(
        FrequencyBucketMode.bands(.musicProduction).bucketCount
          == StandardBands.musicProduction.ranges.count,
      )
    }

    @Test
    func `FrequencyBucketMode default is MEL 24`() {
      let mode = FrequencyBucketMode.default
      #expect(mode == .mel(bucketCount: 24))
    }

    // MARK: - StandardBands Tests

    @Test
    func `StandardBands musicProduction has 7 bands`() {
      let bands = StandardBands.musicProduction
      #expect(bands.ranges.count == 7)
      #expect(bands.ranges.first?.name == "Sub Bass")
      #expect(bands.ranges.last?.name == "Brilliance")
    }

    @Test
    func `StandardBands fiveBand has 5 bands`() {
      let bands = StandardBands.fiveBand
      #expect(bands.ranges.count == 5)
    }

    @Test
    func `StandardBands threeBand has 3 bands`() {
      let bands = StandardBands.threeBand
      #expect(bands.ranges.count == 3)
    }

    // MARK: - BeatDetectionConfiguration Tests

    @Test
    func `BeatDetectionConfiguration default values`() {
      let config = BeatDetectionConfiguration.default
      #expect(config.sensitivity == 0.5)
      #expect(config.minimumBeatInterval == 0.1)
      #expect(config.bassFocused)
      #expect(config.historySize == 43)
    }

    @Test
    func `BeatDetectionConfiguration clamping initializer`() {
      let tooLow = BeatDetectionConfiguration(clampingSensitivity: -0.5)
      #expect(tooLow.sensitivity == 0)

      let tooHigh = BeatDetectionConfiguration(clampingSensitivity: 1.5)
      #expect(tooHigh.sensitivity == 1)

      let normal = BeatDetectionConfiguration(clampingSensitivity: 0.7)
      #expect(normal.sensitivity == 0.7)
    }

    @Test
    func `BeatDetectionConfiguration validating initializer rejects invalid values`() throws {
      do {
        _ = try BeatDetectionConfiguration(validatingSensitivity: -0.1)
        #expect(Bool(false), "Expected validating initializer to throw for invalid sensitivity")
      } catch {
        #expect(
          error
            == .sensitivityOutOfRange(
              actual: -0.1, valid: BeatDetectionConfiguration.validSensitivityRange,
            ),
        )
      }
    }

    @Test
    func `BeatDetectionConfiguration presets`() {
      let high = BeatDetectionConfiguration.highSensitivity
      #expect(high.sensitivity == 0.3)

      let low = BeatDetectionConfiguration.lowSensitivity
      #expect(low.sensitivity == 0.7)
    }

    @Test
    func `Visualization work validating/clamping initializers`() throws {
      let clampedLod = LODWork(clampingConfiguration: .default, publishRateHz: 0)
      #expect(clampedLod.publishRateHz == 1)

      do {
        _ = try LODWork(validatingConfiguration: .default, publishRateHz: 0)
        #expect(Bool(false), "Expected LODWork validating initializer to throw")
      } catch {
        #expect(error == .publishRateMustBePositive(actual: 0))
      }

      let clampedAnalysis = AnalysisWork(clampingUpdateRateHz: 0)
      #expect(clampedAnalysis.updateRateHz == 1)

      do {
        _ = try AnalysisWork(validatingUpdateRateHz: 0)
        #expect(Bool(false), "Expected AnalysisWork validating initializer to throw")
      } catch {
        #expect(error == .updateRateMustBePositive(actual: 0))
      }

      let frequencyConfig = FrequencyAnalyzer.Configuration(
        fftSize: 1024,
        spectrumSize: 512,
        sampleRate: 44100,
        smoothingFactor: 0.3,
        noiseFloor: -60,
        windowType: .hann,
      )
      let clampedFrequencyWork = FrequencyDomainWork(
        clampingConfiguration: frequencyConfig,
        peakHoldDecayRate: -0.25,
      )
      #expect(clampedFrequencyWork.peakHoldDecayRate == 0)

      do {
        _ = try FrequencyDomainWork(
          validatingConfiguration: frequencyConfig,
          peakHoldDecayRate: -0.25,
        )
        #expect(Bool(false), "Expected FrequencyDomainWork validating initializer to throw")
      } catch {
        #expect(error == .peakHoldDecayRateMustBeNonNegative(actual: -0.25))
      }
    }
  }

#endif
