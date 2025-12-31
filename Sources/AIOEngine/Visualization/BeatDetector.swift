#if canImport(Accelerate)
  import Accelerate
  import Foundation

  /// A beat detector that uses energy-based detection with adaptive thresholding.
  ///
  /// The detector analyzes audio energy levels and compares them against a running
  /// average to identify transient peaks that correspond to musical beats.
  ///
  /// This type contains mutable state optimized for single-consumer use (e.g. a dedicated
  /// processing queue). Callers must not invoke `analyze(...)` concurrently on the same
  /// instance.
  public final class BeatDetector {
    // MARK: - Configuration

    private var configuration: BeatDetectionConfiguration

    // MARK: - State

    /// Circular buffer of recent energy values for adaptive thresholding.
    private var energyHistory: [Float]
    private var historyIndex: Int = 0
    private var historyCount: Int = 0

    /// Beat timing history for tempo estimation.
    private var beatTimestamps: [TimeInterval] = []
    private let maxBeatTimestamps = 8

    /// Timing state.
    private var lastBeatTime: TimeInterval = -.infinity
    private var currentTime: TimeInterval = 0

    /// Previous energy for onset detection.
    private var previousEnergy: Float = 0

    // MARK: - Initialization

    /// Creates a new beat detector with the specified configuration.
    public init(configuration: BeatDetectionConfiguration = .default) {
      self.configuration = configuration
      self.energyHistory = Array(repeating: 0, count: configuration.historySize)
    }

    // MARK: - Public Interface

    /// Updates the beat detector configuration.
    public func updateConfiguration(_ configuration: BeatDetectionConfiguration) {
      let oldSize = self.configuration.historySize
      self.configuration = configuration

      // Resize history buffer if needed
      if oldSize != configuration.historySize {
        let newHistory = Array(repeating: Float(0), count: configuration.historySize)
        energyHistory = newHistory
        historyIndex = 0
        historyCount = 0
      }
    }

    /// Analyzes audio data and returns beat detection information.
    ///
    /// - Parameters:
    ///   - spectrum: The frequency spectrum data (normalized [0.0, 1.0]).
    ///   - rmsLevel: The current RMS level (normalized [0.0, 1.0]).
    ///   - deltaTime: Time elapsed since the last call in seconds.
    /// - Returns: Beat detection information including whether a beat was detected.
    public func analyze(
      spectrum: [Float],
      rmsLevel: Float,
      deltaTime: TimeInterval
    ) -> BeatInfo {
      currentTime += deltaTime

      // Calculate energy (focus on bass if configured)
      let energy = calculateEnergy(spectrum: spectrum, rmsLevel: rmsLevel)

      // Update energy history
      addToHistory(energy)

      // Calculate adaptive threshold
      let threshold = calculateThreshold()

      // Detect beat using onset detection
      let beatDetected = detectBeat(energy: energy, threshold: threshold)

      // Calculate time since last beat
      let timeSinceLastBeat = currentTime - lastBeatTime

      // Update beat timing if beat detected
      if beatDetected {
        lastBeatTime = currentTime
        addBeatTimestamp(currentTime)
      }

      // Estimate tempo from beat history
      let tempo = estimateTempo()

      previousEnergy = energy

      return BeatInfo(
        beatDetected: beatDetected,
        energy: energy,
        timeSinceLastBeat: timeSinceLastBeat,
        estimatedTempo: tempo
      )
    }

    /// Resets the beat detector state.
    public func reset() {
      energyHistory = Array(repeating: 0, count: configuration.historySize)
      historyIndex = 0
      historyCount = 0
      beatTimestamps.removeAll()
      lastBeatTime = -.infinity
      currentTime = 0
      previousEnergy = 0
    }

    // MARK: - Private Methods

    private func calculateEnergy(spectrum: [Float], rmsLevel: Float) -> Float {
      guard !spectrum.isEmpty else { return rmsLevel }

      if configuration.bassFocused {
        // Focus on the lower 1/4 of the spectrum (bass frequencies)
        let bassCount = max(1, spectrum.count / 4)
        let bassSpectrum = Array(spectrum.prefix(bassCount))

        // Calculate weighted average of bass frequencies
        var bassEnergy: Float = 0
        vDSP_meanv(bassSpectrum, 1, &bassEnergy, vDSP_Length(bassCount))

        // Combine bass energy with overall RMS, emphasizing bass
        return bassEnergy * 0.7 + rmsLevel * 0.3
      } else {
        // Use full spectrum RMS
        return rmsLevel
      }
    }

    private func addToHistory(_ energy: Float) {
      energyHistory[historyIndex] = energy
      historyIndex = (historyIndex + 1) % configuration.historySize
      historyCount = min(historyCount + 1, configuration.historySize)
    }

    private func calculateThreshold() -> Float {
      guard historyCount > 0 else { return 0.5 }

      // Calculate mean energy
      var mean: Float = 0
      vDSP_meanv(energyHistory, 1, &mean, vDSP_Length(historyCount))

      // Calculate variance for adaptive sensitivity
      var variance: Float = 0
      var temp = [Float](repeating: 0, count: historyCount)

      // temp = history - mean
      var negativeMean = -mean
      vDSP_vsadd(energyHistory, 1, &negativeMean, &temp, 1, vDSP_Length(historyCount))

      // variance = mean(temp^2)
      vDSP_vsq(temp, 1, &temp, 1, vDSP_Length(historyCount))
      vDSP_meanv(temp, 1, &variance, vDSP_Length(historyCount))

      // Standard deviation
      let stdDev = sqrtf(max(variance, 0.0001))

      // Adaptive threshold: mean + (sensitivity factor * stdDev)
      // Higher sensitivity = lower multiplier = more beats detected
      let sensitivityMultiplier = 1.0 + (1.0 - configuration.sensitivity) * 2.0
      return mean + stdDev * sensitivityMultiplier
    }

    private func detectBeat(energy: Float, threshold: Float) -> Bool {
      // Check minimum interval
      let timeSinceLastBeat = currentTime - lastBeatTime
      guard timeSinceLastBeat >= configuration.minimumBeatInterval else {
        return false
      }

      // Onset detection: energy must exceed threshold AND be rising
      let isRising = energy > previousEnergy
      let exceedsThreshold = energy > threshold

      // Additional check: significant energy increase (onset)
      let onsetStrength = energy - previousEnergy
      let hasStrongOnset = onsetStrength > threshold * 0.3

      return exceedsThreshold && isRising && hasStrongOnset
    }

    private func addBeatTimestamp(_ timestamp: TimeInterval) {
      beatTimestamps.append(timestamp)
      if beatTimestamps.count > maxBeatTimestamps {
        beatTimestamps.removeFirst()
      }
    }

    private func estimateTempo() -> Double {
      guard beatTimestamps.count >= 3 else { return 0 }

      // Calculate inter-beat intervals
      var intervals: [TimeInterval] = []
      for i in 1..<beatTimestamps.count {
        let interval = beatTimestamps[i] - beatTimestamps[i - 1]
        // Only consider reasonable intervals (30-200 BPM range)
        if interval >= 0.3 && interval <= 2.0 {
          intervals.append(interval)
        }
      }

      guard !intervals.isEmpty else { return 0 }

      // Calculate median interval (more robust than mean)
      let sortedIntervals = intervals.sorted()
      let medianInterval: TimeInterval
      if sortedIntervals.count % 2 == 0 {
        let mid = sortedIntervals.count / 2
        medianInterval = (sortedIntervals[mid - 1] + sortedIntervals[mid]) / 2
      } else {
        medianInterval = sortedIntervals[sortedIntervals.count / 2]
      }

      // Convert to BPM
      return 60.0 / medianInterval
    }
  }

#endif
