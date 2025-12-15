#if canImport(AVFAudio)
  import Foundation

  // MARK: - Configuration

  /// Configuration for multi-band Level-of-Detail visualization processing.
  ///
  /// This configuration controls how audio is split into frequency bands and
  /// downsampled for efficient GPU-based waveform rendering.
  public struct MultiBandLODConfiguration: Sendable, Equatable {
    /// Number of frequency bands to split audio into (3-8 recommended).
    public let bandCount: Int

    /// Level-of-detail reduction ratio (samples per LOD bucket).
    /// Default is 128, meaning 128 raw samples become 1 LOD sample.
    public let lodRatio: Int

    /// Maximum buffer duration in seconds.
    /// Default is 300 (5 minutes).
    public let bufferSeconds: Int

    /// Audio sample rate in Hz.
    /// Default is 44100.
    public let sampleRate: Int

    /// How to split frequencies across bands.
    public let crossoverMode: CrossoverMode

    /// Number of LOD commits between snapshot slot swaps.
    /// Controls how frequently the render thread sees updated data.
    /// Default is 6, which at 44100Hz with lodRatio=128 gives ~57fps updates.
    /// Lower values = more frequent updates but more atomic operations.
    /// Higher values = less frequent updates but lower overhead.
    public let snapshotSwapInterval: Int

    /// Computed property: number of raw samples in the buffer.
    public var rawBufferLength: Int {
      let (rawBufferLength, overflow) = sampleRate.multipliedReportingOverflow(by: bufferSeconds)
      precondition(
        !overflow,
        "MultiBandLODConfiguration.rawBufferLength overflow: sampleRate=\(sampleRate) bufferSeconds=\(bufferSeconds)"
      )
      return rawBufferLength
    }

    /// Computed property: number of LOD samples per band.
    public var lodBufferLength: Int {
      Int(ceil(Double(rawBufferLength) / Double(lodRatio)))
    }

    /// Creates a new multi-band LOD configuration.
    ///
    /// - Parameters:
    ///   - bandCount: Number of frequency bands (3-8). Default: 5.
    ///   - lodRatio: Samples per LOD bucket. Default: 128.
    ///   - bufferSeconds: Maximum buffer duration. Default: 300.
    ///   - sampleRate: Audio sample rate. Default: 44100.
    ///   - crossoverMode: Frequency splitting mode. Default: Mel scale.
    ///   - snapshotSwapInterval: LOD commits between slot swaps. Default: 6 (~57fps).
    public init(
      bandCount: Int = 5,
      lodRatio: Int = 128,
      bufferSeconds: Int = 300,
      sampleRate: Int = 44_100,
      crossoverMode: CrossoverMode = .mel(minFreq: 40, maxFreq: 15000),
      snapshotSwapInterval: Int = 6
    ) {
      self.bandCount = max(1, min(8, bandCount))
      self.lodRatio = max(1, lodRatio)
      self.bufferSeconds = max(1, bufferSeconds)
      self.sampleRate = max(1, sampleRate)
      self.crossoverMode = crossoverMode
      self.snapshotSwapInterval = max(1, snapshotSwapInterval)
    }

    /// Default configuration optimized for real-time recording visualization.
    public static let `default` = MultiBandLODConfiguration()

    /// Configuration for shorter recordings (1 minute buffer).
    public static let shortRecording = MultiBandLODConfiguration(
      bandCount: 5,
      lodRatio: 128,
      bufferSeconds: 60
    )

    /// High-detail configuration with more bands.
    public static let highDetail = MultiBandLODConfiguration(
      bandCount: 8,
      lodRatio: 64,
      bufferSeconds: 300
    )
  }

  // MARK: - Crossover Mode

  /// Defines how frequencies are split across bands.
  public enum CrossoverMode: Sendable, Equatable {
    /// Mel scale splitting (perceptually uniform).
    /// Places more bands in lower frequencies where human hearing is more sensitive.
    case mel(minFreq: Float, maxFreq: Float)

    /// Linear frequency splitting.
    /// Each band covers an equal frequency range.
    case linear(minFreq: Float, maxFreq: Float)

    /// Custom crossover frequencies.
    /// Specify exact cutoff frequencies between bands.
    case custom(frequencies: [Float])

    /// Compute filter alpha values for cascading lowpass filters.
    ///
    /// - Parameters:
    ///   - bandCount: Number of bands to split into.
    ///   - sampleRate: Audio sample rate.
    /// - Returns: Array of alpha values for each crossover point.
    public func computeAlphas(bandCount: Int, sampleRate: Int) -> [Float] {
      let nyquist = Float(sampleRate) * 0.5

      func clampFrequency(_ f: Float) -> Float {
        let maxF = max(1.0, nyquist * 0.98)
        return min(max(f, 1.0), maxF)
      }

      func alphaForCutoff(_ cutoffHz: Float) -> Float {
        let f = clampFrequency(cutoffHz)
        let sr = max(Float(sampleRate), 1.0)
        let alpha = 1.0 - exp((-2.0 * Float.pi * f) / sr)
        return min(max(alpha, 0.0), 1.0)
      }

      let desiredCutoffCount = max(bandCount - 1, 0)
      var cutoffFrequencies: [Float] = []
      cutoffFrequencies.reserveCapacity(desiredCutoffCount)

      switch self {
      case .mel(let minFreq, let maxFreq):
        // Mel scale conversion functions
        func hzToMel(_ hz: Float) -> Float {
          2595 * log10(1 + hz / 700)
        }
        func melToHz(_ mel: Float) -> Float {
          700 * (pow(10, mel / 2595) - 1)
        }

        let minHz = clampFrequency(min(minFreq, maxFreq))
        let maxHz = clampFrequency(max(minFreq, maxFreq))
        let minMel = hzToMel(minHz)
        let maxMel = hzToMel(maxHz)

        for i in 1..<(desiredCutoffCount + 1) {
          let t = Float(i) / Float(bandCount)
          let mel = minMel + (t * (maxMel - minMel))
          let freq = melToHz(mel)
          cutoffFrequencies.append(freq)
        }

      case .linear(let minFreq, let maxFreq):
        let minHz = clampFrequency(min(minFreq, maxFreq))
        let maxHz = clampFrequency(max(minFreq, maxFreq))
        let range = maxHz - minHz
        for i in 1..<(desiredCutoffCount + 1) {
          let t = Float(i) / Float(bandCount)
          cutoffFrequencies.append(minHz + (t * range))
        }

      case .custom(let frequencies):
        let cleaned =
          frequencies
          .map(clampFrequency)
          .sorted()

        cutoffFrequencies = Array(cleaned.prefix(desiredCutoffCount))

        if cutoffFrequencies.count < desiredCutoffCount {
          #if DEBUG
            assertionFailure(
              "CrossoverMode.custom expected \(desiredCutoffCount) frequencies, got \(frequencies.count). Padding to fit bandCount."
            )
          #endif
          let start = cutoffFrequencies.last ?? clampFrequency(40)
          let end = clampFrequency(nyquist * 0.98)
          let remaining = desiredCutoffCount - cutoffFrequencies.count
          if remaining > 0 {
            let step = (end - start) / Float(remaining + 1)
            for i in 1...remaining {
              cutoffFrequencies.append(start + (Float(i) * step))
            }
          }
        }
      }

      cutoffFrequencies = cutoffFrequencies.map(clampFrequency)

      // Ensure strictly ascending cutoffs (avoid accidental duplicates after clamping).
      if cutoffFrequencies.count >= 2 {
        for i in 1..<cutoffFrequencies.count {
          if cutoffFrequencies[i] <= cutoffFrequencies[i - 1] {
            cutoffFrequencies[i] = min(cutoffFrequencies[i - 1] + 1.0, nyquist * 0.98)
          }
        }
      }

      var alphas = cutoffFrequencies.map(alphaForCutoff)

      // Keep a trailing value for diagnostics/debugging parity with older code paths.
      alphas.append(1.0)

      return alphas
    }
  }

  // MARK: - LOD Data Types

  /// LOD (Level-of-Detail) data for a single frequency band.
  ///
  /// Contains min, max, and RMS values computed over LOD windows.
  /// Data is stored in circular buffers for efficient streaming.
  public struct BandLODData: Sendable, Equatable {
    /// Index of this band (0 = lowest frequency).
    public let bandIndex: Int

    /// Minimum amplitude values per LOD window.
    /// Values are in the range [-1.0, 1.0] (linear amplitude).
    public var minBuffer: [Float]

    /// Maximum amplitude values per LOD window.
    /// Values are in the range [-1.0, 1.0] (linear amplitude).
    public var maxBuffer: [Float]

    /// RMS (Root Mean Square) amplitude values per LOD window.
    /// Values are in the range [0.0, 1.0] (linear amplitude).
    public var rmsBuffer: [Float]

    /// Creates a new band LOD data container.
    ///
    /// - Parameters:
    ///   - bandIndex: Index of this band.
    ///   - capacity: Number of LOD samples to allocate.
    public init(bandIndex: Int, capacity: Int) {
      self.bandIndex = bandIndex
      self.minBuffer = Array(repeating: 0, count: capacity)
      self.maxBuffer = Array(repeating: 0, count: capacity)
      self.rmsBuffer = Array(repeating: 0, count: capacity)
    }
  }

  /// Complete multi-band LOD snapshot ready for GPU rendering.
  ///
  /// Contains all band data plus metadata needed by Metal shaders.
  public struct MultiBandLODSnapshot: Sendable, Equatable {
    /// LOD data for each frequency band (indexed by band number).
    public let bands: [BandLODData]

    /// Current write position in circular buffers.
    public let writeIndex: Int

    /// LOD reduction ratio used.
    public let lodRatio: Int

    /// Raw buffer length (for shader calculations).
    public let rawBufferLength: Int

    /// Number of bands.
    public var bandCount: Int { bands.count }

    /// LOD buffer length per band.
    public var lodBufferLength: Int {
      bands.first?.minBuffer.count ?? 0
    }

    /// Creates a new multi-band LOD snapshot.
    public init(
      bands: [BandLODData],
      writeIndex: Int,
      lodRatio: Int,
      rawBufferLength: Int
    ) {
      self.bands = bands
      self.writeIndex = writeIndex
      self.lodRatio = lodRatio
      self.rawBufferLength = rawBufferLength
    }

    /// Empty snapshot with no data.
    public static let empty = MultiBandLODSnapshot(
      bands: [],
      writeIndex: 0,
      lodRatio: 128,
      rawBufferLength: 0
    )

    // MARK: - GPU Buffer Helpers

    /// Creates a flat float array of min values for all bands.
    /// Format: [Band0 LOD samples...][Band1 LOD samples...]...
    public func flatMinBuffer() -> [Float] {
      bands.flatMap { $0.minBuffer }
    }

    /// Creates a flat float array of max values for all bands.
    /// Format: [Band0 LOD samples...][Band1 LOD samples...]...
    public func flatMaxBuffer() -> [Float] {
      bands.flatMap { $0.maxBuffer }
    }

    /// Creates a flat float array of RMS values for all bands.
    /// Format: [Band0 LOD samples...][Band1 LOD samples...]...
    public func flatRMSBuffer() -> [Float] {
      bands.flatMap { $0.rmsBuffer }
    }
  }

#endif
