#if canImport(Accelerate)
  import Accelerate
  import Foundation

  /// Converts raw spectrum data into frequency buckets with configurable grouping.
  ///
  /// Supports MEL scale, logarithmic, linear, and predefined band configurations.
  public final class FrequencyBucketer {
    // MARK: - Configuration

    private var mode: FrequencyBucketMode
    private let sampleRate: Float
    private let nyquist: Float
    private var weighting: FrequencyWeighting

    // MARK: - Precomputed Data

    /// Precomputed bucket boundaries.
    private var bucketBoundaries: [(low: Float, high: Float)] = []

    /// Mapping from spectrum indices to bucket indices.
    private var spectrumToBucketMap: [Int] = []

    /// Per-bucket perceptual weights.
    private var bucketWeights: [Float] = []

    /// Peak hold values for each bucket (with decay).
    private var peakHoldValues: [Float] = []

    /// Decay rate for peak hold (per frame).
    private var peakHoldDecayRate: Float

    // MARK: - Initialization

    /// Creates a new frequency bucketer.
    ///
    /// - Parameters:
    ///   - mode: The bucketing mode to use.
    ///   - sampleRate: The audio sample rate in Hz.
    ///   - peakHoldDecayRate: Decay applied to peak hold values each update.
    public init(
      mode: FrequencyBucketMode = .default,
      sampleRate: Float = 44100,
      peakHoldDecayRate: Float = 0.015,
      weighting: FrequencyWeighting = .none
    ) {
      self.mode = mode
      self.sampleRate = sampleRate
      self.nyquist = sampleRate / 2
      self.peakHoldDecayRate = max(0, peakHoldDecayRate)
      self.weighting = weighting

      computeBucketBoundaries()
    }

    // MARK: - Public Interface

    /// Updates the bucketing mode.
    public func updateMode(_ mode: FrequencyBucketMode) {
      guard self.mode != mode else { return }
      self.mode = mode
      computeBucketBoundaries()
    }

    /// Updates the peak hold decay rate.
    public func updatePeakHoldDecayRate(_ rate: Float) {
      peakHoldDecayRate = max(0, rate)
    }

    /// Updates the perceptual weighting mode.
    public func updateWeighting(_ weighting: FrequencyWeighting) {
      guard self.weighting != weighting else { return }
      self.weighting = weighting
      computeBucketWeights()
    }

    /// The current bucketing mode.
    public var currentMode: FrequencyBucketMode { mode }

    /// Converts raw spectrum data into frequency buckets.
    ///
    /// - Parameters:
    ///   - spectrum: Raw spectrum magnitudes (normalized [0.0, 1.0]).
    ///   - frequencies: Frequency values for each spectrum bin.
    /// - Returns: Array of frequency buckets with magnitude and peak hold values.
    public func bucket(spectrum: [Float], frequencies: [Float]) -> [FrequencyBucket] {
      guard !spectrum.isEmpty, !frequencies.isEmpty else {
        return createEmptyBuckets()
      }

      // Update spectrum-to-bucket mapping if spectrum size changed
      if spectrumToBucketMap.count != spectrum.count {
        computeSpectrumMapping(spectrumSize: spectrum.count, frequencies: frequencies)
      }

      // Aggregate spectrum values into buckets
      var bucketSums = [Float](repeating: 0, count: bucketBoundaries.count)
      var bucketCounts = [Int](repeating: 0, count: bucketBoundaries.count)

      for (spectrumIndex, bucketIndex) in spectrumToBucketMap.enumerated() {
        guard bucketIndex >= 0, bucketIndex < bucketBoundaries.count else { continue }
        guard spectrumIndex < spectrum.count else { break }

        bucketSums[bucketIndex] += spectrum[spectrumIndex]
        bucketCounts[bucketIndex] += 1
      }

      // Calculate average magnitude for each bucket and update peak hold
      var buckets: [FrequencyBucket] = []
      buckets.reserveCapacity(bucketBoundaries.count)

      // Ensure peak hold array is properly sized
      if peakHoldValues.count != bucketBoundaries.count {
        peakHoldValues = [Float](repeating: 0, count: bucketBoundaries.count)
      }

      for (index, boundary) in bucketBoundaries.enumerated() {
        let count = bucketCounts[index]
        let magnitude = count > 0 ? bucketSums[index] / Float(count) : 0
        let weight = bucketWeights.count > index ? bucketWeights[index] : 1
        let weightedMagnitude = magnitude * weight

        // Update peak hold with decay
        let decayedPeak = max(0, peakHoldValues[index] - peakHoldDecayRate)
        peakHoldValues[index] = max(decayedPeak, weightedMagnitude)

        buckets.append(
          FrequencyBucket(
            id: index,
            lowFrequency: boundary.low,
            highFrequency: boundary.high,
            magnitude: weightedMagnitude,
            peakHold: peakHoldValues[index]
          ))
      }

      return buckets
    }

    /// Resets all peak hold values to zero.
    public func resetPeakHold() {
      peakHoldValues = [Float](repeating: 0, count: bucketBoundaries.count)
    }

    // MARK: - Private Methods

    private func computeBucketBoundaries() {
      switch mode {
      case .mel(let count):
        bucketBoundaries = computeMelBoundaries(count: count)
      case .logarithmic(let count):
        bucketBoundaries = computeLogarithmicBoundaries(count: count)
      case .linear(let count):
        bucketBoundaries = computeLinearBoundaries(count: count)
      case .bands(let bands):
        bucketBoundaries = bands.ranges.map { (low: $0.low, high: $0.high) }
      }

      // Reset peak hold for new bucket count
      peakHoldValues = [Float](repeating: 0, count: bucketBoundaries.count)
      computeBucketWeights()
      // Clear spectrum mapping to force recomputation
      spectrumToBucketMap = []
    }

    private func computeMelBoundaries(count: Int) -> [(low: Float, high: Float)] {
      guard count > 0 else { return [] }

      let minMel = hertzToMel(20)  // Start at 20 Hz
      let maxMel = hertzToMel(nyquist)
      let melStep = (maxMel - minMel) / Float(count)

      var boundaries: [(low: Float, high: Float)] = []
      boundaries.reserveCapacity(count)

      for i in 0..<count {
        let lowMel = minMel + Float(i) * melStep
        let highMel = minMel + Float(i + 1) * melStep
        let lowHz = melToHertz(lowMel)
        let highHz = melToHertz(highMel)
        boundaries.append((low: lowHz, high: highHz))
      }

      return boundaries
    }

    private func computeLogarithmicBoundaries(count: Int) -> [(low: Float, high: Float)] {
      guard count > 0 else { return [] }

      let minFreq: Float = 20
      let maxFreq = nyquist
      let logMin = log10(minFreq)
      let logMax = log10(maxFreq)
      let logStep = (logMax - logMin) / Float(count)

      var boundaries: [(low: Float, high: Float)] = []
      boundaries.reserveCapacity(count)

      for i in 0..<count {
        let lowLog = logMin + Float(i) * logStep
        let highLog = logMin + Float(i + 1) * logStep
        let lowHz = pow(10, lowLog)
        let highHz = pow(10, highLog)
        boundaries.append((low: lowHz, high: highHz))
      }

      return boundaries
    }

    private func computeLinearBoundaries(count: Int) -> [(low: Float, high: Float)] {
      guard count > 0 else { return [] }

      let minFreq: Float = 20
      let maxFreq = nyquist
      let freqStep = (maxFreq - minFreq) / Float(count)

      var boundaries: [(low: Float, high: Float)] = []
      boundaries.reserveCapacity(count)

      for i in 0..<count {
        let lowHz = minFreq + Float(i) * freqStep
        let highHz = minFreq + Float(i + 1) * freqStep
        boundaries.append((low: lowHz, high: highHz))
      }

      return boundaries
    }

    private func computeSpectrumMapping(spectrumSize: Int, frequencies: [Float]) {
      spectrumToBucketMap = [Int](repeating: -1, count: spectrumSize)

      for spectrumIndex in 0..<min(spectrumSize, frequencies.count) {
        let frequency = frequencies[spectrumIndex]

        // Find the bucket this frequency belongs to
        for (bucketIndex, boundary) in bucketBoundaries.enumerated() {
          if frequency >= boundary.low && frequency < boundary.high {
            spectrumToBucketMap[spectrumIndex] = bucketIndex
            break
          }
        }

        // Handle frequencies at the upper boundary
        if let lastBoundary = bucketBoundaries.last,
          frequency >= lastBoundary.low && frequency <= lastBoundary.high
        {
          spectrumToBucketMap[spectrumIndex] = bucketBoundaries.count - 1
        }
      }
    }

    private func createEmptyBuckets() -> [FrequencyBucket] {
      bucketBoundaries.enumerated().map { index, boundary in
        FrequencyBucket(
          id: index,
          lowFrequency: boundary.low,
          highFrequency: boundary.high,
          magnitude: 0,
          peakHold: max(
            0,
            peakHoldValues.count > index
              ? peakHoldValues[index] - peakHoldDecayRate
              : 0
          )
        )
      }
    }

    private func computeBucketWeights() {
      guard !bucketBoundaries.isEmpty else {
        bucketWeights = []
        return
      }

      switch weighting {
      case .none:
        bucketWeights = [Float](repeating: 1, count: bucketBoundaries.count)
      case .aWeighting:
        var weights: [Float] = []
        weights.reserveCapacity(bucketBoundaries.count)
        for boundary in bucketBoundaries {
          let center = max(1, (boundary.low + boundary.high) * 0.5)
          let weightDb = aWeightingDecibels(frequency: center)
          let linear = pow(10, weightDb / 20)
          weights.append(linear.isFinite ? linear : 1)
        }
        let maxWeight = weights.max() ?? 1
        let scale = maxWeight > 0 ? (1 / maxWeight) : 1
        bucketWeights = weights.map { $0 * scale }
      }
    }

    private func aWeightingDecibels(frequency: Float) -> Float {
      guard frequency > 0 else { return -80 }

      let f2 = frequency * frequency
      let term1 = f2 + 20.6 * 20.6
      let term2 = f2 + 107.7 * 107.7
      let term3 = f2 + 737.9 * 737.9
      let term4 = f2 + 12_200 * 12_200
      let numerator = 12_200 * 12_200 * f2 * f2
      let denominator = term1 * sqrt(term2 * term3) * term4
      guard denominator > 0 else { return -80 }
      let ra = numerator / denominator
      return 2.0 + 20 * log10(ra)
    }

    // MARK: - Mel Scale Conversion

    private func hertzToMel(_ hz: Float) -> Float {
      2595 * log10(1 + hz / 700)
    }

    private func melToHertz(_ mel: Float) -> Float {
      700 * (pow(10, mel / 2595) - 1)
    }
  }

#endif
