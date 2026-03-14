// © GoodHatsLLC

#if canImport(AVFAudio)
  public import Foundation

  /// Shared default rates for visualization pipelines.
  public enum VisualizationRateDefaults: Sendable {
    public static let lodPublishRateHz: Double = 60
    public static let analysisUpdateRateHz: Double = 30
  }

  // MARK: - Time Domain Data

  /// Time-domain audio visualization data providing amplitude and level information.
  public struct TimeDomainData: Sendable, Equatable {
    /// Normalized amplitude samples in the range [0.0, 1.0].
    /// These represent the smoothed absolute amplitude values across the analysis window.
    public var samples: [Float]

    /// Peak amplitude values with decay for peak-hold visualization.
    /// Values decay over time to create the classic "peak meter" effect.
    public var peaks: [Float]

    /// Current RMS (Root Mean Square) level in the range [0.0, 1.0].
    /// Represents the overall energy of the audio signal.
    public var rmsLevel: Float

    /// Overall amplitude level (maximum of samples) in the range [0.0, 1.0].
    public var level: Float

    /// Creates a new time-domain data container.
    public init(samples: [Float] = [], peaks: [Float] = [], rmsLevel: Float = 0, level: Float = 0) {
      self.samples = samples
      self.peaks = peaks
      self.rmsLevel = rmsLevel
      self.level = level
    }

    /// Empty time-domain data.
    public static let empty = TimeDomainData()
  }

  // MARK: - Frequency Domain Data

  /// Frequency-domain audio visualization data providing spectrum analysis information.
  public struct FrequencyDomainData: Sendable, Equatable {
    /// Frequency buckets with configurable grouping.
    /// Each bucket represents a frequency band with magnitude and peak hold values.
    public var buckets: [FrequencyBucket]

    /// Raw spectrum data for advanced usage.
    /// Normalized magnitudes in the range [0.0, 1.0].
    public var rawSpectrum: [Float]

    /// Frequencies corresponding to each raw spectrum bin (in Hz).
    public var frequencies: [Float]

    /// Peak frequency in Hz (the frequency with the highest magnitude).
    public var peakFrequency: Float

    /// Spectral centroid in Hz (a "brightness" measure of the audio).
    /// Higher values indicate brighter/treblier audio content.
    public var spectralCentroid: Float

    /// Creates a new frequency-domain data container.
    public init(
      buckets: [FrequencyBucket] = [],
      rawSpectrum: [Float] = [],
      frequencies: [Float] = [],
      peakFrequency: Float = 0,
      spectralCentroid: Float = 0,
    ) {
      self.buckets = buckets
      self.rawSpectrum = rawSpectrum
      self.frequencies = frequencies
      self.peakFrequency = peakFrequency
      self.spectralCentroid = spectralCentroid
    }

    /// Empty frequency-domain data.
    public static let empty = FrequencyDomainData()
  }

  /// A single frequency bucket representing a band of frequencies.
  public struct FrequencyBucket: Sendable, Equatable, Identifiable {
    /// Unique identifier for the bucket.
    public var id: Int

    /// Lower frequency bound of this bucket in Hz.
    public var lowFrequency: Float

    /// Upper frequency bound of this bucket in Hz.
    public var highFrequency: Float

    /// Center frequency of this bucket in Hz.
    public var centerFrequency: Float {
      (lowFrequency + highFrequency) / 2
    }

    /// Human-readable label for this frequency range.
    public var label: String {
      let cf = centerFrequency
      if cf >= 1000 {
        let k = cf / 1000.0
        let formatted = k.formatted(
          .number
            .precision(.fractionLength(0...1))
            .grouping(.never),
        )
        return "\(formatted)k"
      } else {
        return cf.formatted(
          .number
            .precision(.fractionLength(0...0))
            .grouping(.never),
        )
      }
    }

    /// Magnitude of this bucket in the range [0.0, 1.0].
    public var magnitude: Float

    /// Peak hold value with decay in the range [0.0, 1.0].
    public var peakHold: Float

    /// Creates a new frequency bucket.
    public init(
      id: Int,
      lowFrequency: Float,
      highFrequency: Float,
      magnitude: Float = 0,
      peakHold: Float = 0,
    ) {
      self.id = id
      self.lowFrequency = lowFrequency
      self.highFrequency = highFrequency
      self.magnitude = magnitude
      self.peakHold = peakHold
    }
  }

  // MARK: - Beat Detection

  /// Information about detected beats in the audio signal.
  public struct BeatInfo: Sendable, Equatable {
    /// Whether a beat was detected in the current frame.
    public var beatDetected: Bool

    /// The energy level that triggered the beat detection.
    /// In the range [0.0, 1.0].
    public var energy: Float

    /// Time since the last detected beat in seconds.
    public var timeSinceLastBeat: TimeInterval

    /// Estimated tempo in BPM (beats per minute), if enough beats have been detected.
    /// Will be 0 if tempo cannot yet be estimated.
    public var estimatedTempo: Double

    /// Creates a new beat info container.
    public init(
      beatDetected: Bool = false,
      energy: Float = 0,
      timeSinceLastBeat: TimeInterval = .infinity,
      estimatedTempo: Double = 0,
    ) {
      self.beatDetected = beatDetected
      self.energy = energy
      self.timeSinceLastBeat = timeSinceLastBeat
      self.estimatedTempo = estimatedTempo
    }

    /// Empty beat info (no beat detected).
    public static let empty = BeatInfo()
  }

  // MARK: - Frequency Bucket Configuration

  /// Configuration for how frequency data should be bucketed for visualization.
  public enum FrequencyBucketMode: Sendable, Equatable {
    /// Use MEL scale bucketing (perceptually uniform spacing).
    /// This places more buckets in the lower frequencies where human hearing is more sensitive.
    case mel(bucketCount: Int)

    /// Use logarithmic (octave-based) bucketing.
    /// Each bucket spans approximately the same musical interval.
    case logarithmic(bucketCount: Int)

    /// Use linear scale bucketing (uniform frequency spacing).
    /// Each bucket spans the same frequency range.
    case linear(bucketCount: Int)

    /// Use predefined standard frequency bands.
    case bands(StandardBands)

    /// The number of buckets this configuration will produce.
    public var bucketCount: Int {
      switch self {
      case .mel(let count), .logarithmic(let count), .linear(let count):
        count
      case .bands(let bands):
        bands.ranges.count
      }
    }

    /// Default configuration: 24 MEL-scale buckets.
    public static let `default` = FrequencyBucketMode.mel(bucketCount: 24)
  }

  /// Perceptual weighting applied to frequency bucket magnitudes.
  public enum FrequencyWeighting: Sendable, Equatable {
    /// No perceptual weighting.
    case none
    /// A-weighting (approximates human loudness sensitivity).
    case aWeighting
  }

  /// Standard predefined frequency bands for audio analysis.
  public struct StandardBands: Sendable, Equatable {
    /// The frequency ranges for each band.
    public let ranges: [(name: String, low: Float, high: Float)]

    /// Standard audio frequency bands used in music production.
    public static let musicProduction = StandardBands(ranges: [
      ("Sub Bass", 20, 60),
      ("Bass", 60, 250),
      ("Low Mid", 250, 500),
      ("Mid", 500, 2000),
      ("High Mid", 2000, 4000),
      ("Presence", 4000, 6000),
      ("Brilliance", 6000, 20000),
    ])

    /// Simplified 5-band EQ style bands.
    public static let fiveBand = StandardBands(ranges: [
      ("Bass", 20, 140),
      ("Low Mid", 140, 400),
      ("Mid", 400, 2500),
      ("High Mid", 2500, 5000),
      ("Treble", 5000, 20000),
    ])

    /// 3-band simplified analysis.
    public static let threeBand = StandardBands(ranges: [
      ("Low", 20, 250),
      ("Mid", 250, 4000),
      ("High", 4000, 20000),
    ])
  }

  extension StandardBands {
    public static func == (lhs: StandardBands, rhs: StandardBands) -> Bool {
      guard lhs.ranges.count == rhs.ranges.count else { return false }
      for (l, r) in zip(lhs.ranges, rhs.ranges) {
        if l.name != r.name || l.low != r.low || l.high != r.high {
          return false
        }
      }
      return true
    }
  }

  // MARK: - Beat Detection Configuration

  /// Configuration for beat detection behavior.
  public struct BeatDetectionConfiguration: Sendable, Equatable {
    public enum ValidationError: Error, Sendable, Equatable, CustomStringConvertible {
      case sensitivityOutOfRange(actual: Float, valid: ClosedRange<Float>)
      case minimumBeatIntervalMustBeNonNegative(actual: TimeInterval)
      case historySizeMustBePositive(actual: Int)

      public var description: String {
        switch self {
        case .sensitivityOutOfRange(let actual, let valid):
          "sensitivity must be in \(valid), got \(actual)"
        case .minimumBeatIntervalMustBeNonNegative(let actual):
          "minimumBeatInterval must be >= 0, got \(actual)"
        case .historySizeMustBePositive(let actual):
          "historySize must be > 0, got \(actual)"
        }
      }
    }

    public static let validSensitivityRange: ClosedRange<Float> = 0...1

    /// Sensitivity threshold for beat detection.
    /// Higher values require louder transients to trigger a beat.
    /// Range: [0.0, 1.0], default: 0.5
    public var sensitivity: Float

    /// Minimum time between beats in seconds.
    /// Prevents detecting multiple beats in rapid succession.
    /// Default: 0.1 (allows up to 600 BPM)
    public var minimumBeatInterval: TimeInterval

    /// Whether to use bass-focused beat detection.
    /// When true, beat detection emphasizes low frequencies.
    /// Default: true
    public var bassFocused: Bool

    /// Number of energy history samples to use for adaptive thresholding.
    /// Default: 43 (approximately 1 second at 60 FPS)
    public var historySize: Int

    /// Creates a beat detection configuration.
    public init(
      sensitivity: Float = 0.5,
      minimumBeatInterval: TimeInterval = 0.1,
      bassFocused: Bool = true,
      historySize: Int = 43,
    ) {
      precondition(
        Self.validSensitivityRange.contains(sensitivity),
        "BeatDetectionConfiguration.sensitivity must be in \(Self.validSensitivityRange), got \(sensitivity)",
      )
      precondition(
        minimumBeatInterval >= 0,
        "BeatDetectionConfiguration.minimumBeatInterval must be >= 0, got \(minimumBeatInterval)",
      )
      precondition(
        historySize > 0,
        "BeatDetectionConfiguration.historySize must be > 0, got \(historySize)",
      )
      self.sensitivity = sensitivity
      self.minimumBeatInterval = minimumBeatInterval
      self.bassFocused = bassFocused
      self.historySize = historySize
    }

    /// Creates a configuration from untrusted values and throws on invalid input.
    public init(
      validatingSensitivity sensitivity: Float,
      minimumBeatInterval: TimeInterval = 0.1,
      bassFocused: Bool = true,
      historySize: Int = 43,
    ) throws(ValidationError) {
      guard Self.validSensitivityRange.contains(sensitivity) else {
        throw .sensitivityOutOfRange(actual: sensitivity, valid: Self.validSensitivityRange)
      }
      guard minimumBeatInterval >= 0 else {
        throw .minimumBeatIntervalMustBeNonNegative(actual: minimumBeatInterval)
      }
      guard historySize > 0 else {
        throw .historySizeMustBePositive(actual: historySize)
      }
      self.init(
        sensitivity: sensitivity,
        minimumBeatInterval: minimumBeatInterval,
        bassFocused: bassFocused,
        historySize: historySize,
      )
    }

    /// Convenience initializer that clamps out-of-range values.
    public init(
      clampingSensitivity sensitivity: Float,
      minimumBeatInterval: TimeInterval = 0.1,
      bassFocused: Bool = true,
      historySize: Int = 43,
    ) {
      self.init(
        sensitivity: min(
          max(sensitivity, Self.validSensitivityRange.lowerBound),
          Self.validSensitivityRange.upperBound,
        ),
        minimumBeatInterval: max(0, minimumBeatInterval),
        bassFocused: bassFocused,
        historySize: max(1, historySize),
      )
    }

    /// Default configuration optimized for general music.
    public static let `default` = BeatDetectionConfiguration()

    /// High sensitivity configuration for detecting subtle beats.
    public static let highSensitivity = BeatDetectionConfiguration(
      sensitivity: 0.3,
      minimumBeatInterval: 0.08,
    )

    /// Low sensitivity configuration for strong, clear beats only.
    public static let lowSensitivity = BeatDetectionConfiguration(
      sensitivity: 0.7,
      minimumBeatInterval: 0.15,
    )
  }

  // MARK: - Visualization Work Registration

  /// Declarative work specification for visualization pipelines.
  public struct VisualizationWork: Sendable, Equatable {
    public var lod: LODWork?
    public var analysis: AnalysisWork?

    public init(lod: LODWork? = nil, analysis: AnalysisWork? = nil) {
      self.lod = lod
      self.analysis = analysis
    }

    public static let none = VisualizationWork()
  }

  /// LOD (multi-band waveform) processing requirements.
  public struct LODWork: Sendable, Equatable {
    public enum ValidationError: Error, Sendable, Equatable, CustomStringConvertible {
      case publishRateMustBePositive(actual: Double)

      public var description: String {
        switch self {
        case .publishRateMustBePositive(let actual):
          "publishRateHz must be > 0, got \(actual)"
        }
      }
    }

    public var configuration: MultiBandLODConfiguration
    public var publishRateHz: Double

    public init(
      configuration: MultiBandLODConfiguration = .default,
      publishRateHz: Double = VisualizationRateDefaults.lodPublishRateHz,
    ) {
      precondition(
        publishRateHz > 0,
        "LODWork.publishRateHz must be > 0, got \(publishRateHz)",
      )
      self.configuration = configuration
      self.publishRateHz = publishRateHz
    }

    public init(
      validatingConfiguration configuration: MultiBandLODConfiguration,
      publishRateHz: Double = VisualizationRateDefaults.lodPublishRateHz,
    ) throws(ValidationError) {
      guard publishRateHz > 0 else {
        throw .publishRateMustBePositive(actual: publishRateHz)
      }
      self.init(configuration: configuration, publishRateHz: publishRateHz)
    }

    public init(
      clampingConfiguration configuration: MultiBandLODConfiguration,
      publishRateHz: Double = VisualizationRateDefaults.lodPublishRateHz,
    ) {
      self.init(
        configuration: configuration,
        publishRateHz: max(1, publishRateHz),
      )
    }
  }

  /// Analysis processing requirements for time/frequency/beat data.
  public struct AnalysisWork: Sendable, Equatable {
    public enum ValidationError: Error, Sendable, Equatable, CustomStringConvertible {
      case updateRateMustBePositive(actual: Double)

      public var description: String {
        switch self {
        case .updateRateMustBePositive(let actual):
          "updateRateHz must be > 0, got \(actual)"
        }
      }
    }

    public var updateRateHz: Double
    public var timeDomain: AmplitudeAnalyzer.Configuration?
    public var frequencyDomain: FrequencyDomainWork?
    public var beatDetection: BeatDetectionConfiguration?

    public init(
      updateRateHz: Double = VisualizationRateDefaults.analysisUpdateRateHz,
      timeDomain: AmplitudeAnalyzer.Configuration? = nil,
      frequencyDomain: FrequencyDomainWork? = nil,
      beatDetection: BeatDetectionConfiguration? = nil,
    ) {
      precondition(
        updateRateHz > 0,
        "AnalysisWork.updateRateHz must be > 0, got \(updateRateHz)",
      )
      self.updateRateHz = updateRateHz
      self.timeDomain = timeDomain
      self.frequencyDomain = frequencyDomain
      self.beatDetection = beatDetection
    }

    public init(
      validatingUpdateRateHz updateRateHz: Double,
      timeDomain: AmplitudeAnalyzer.Configuration? = nil,
      frequencyDomain: FrequencyDomainWork? = nil,
      beatDetection: BeatDetectionConfiguration? = nil,
    ) throws(ValidationError) {
      guard updateRateHz > 0 else {
        throw .updateRateMustBePositive(actual: updateRateHz)
      }
      self.init(
        updateRateHz: updateRateHz,
        timeDomain: timeDomain,
        frequencyDomain: frequencyDomain,
        beatDetection: beatDetection,
      )
    }

    public init(
      clampingUpdateRateHz updateRateHz: Double,
      timeDomain: AmplitudeAnalyzer.Configuration? = nil,
      frequencyDomain: FrequencyDomainWork? = nil,
      beatDetection: BeatDetectionConfiguration? = nil,
    ) {
      self.init(
        updateRateHz: max(1, updateRateHz),
        timeDomain: timeDomain,
        frequencyDomain: frequencyDomain,
        beatDetection: beatDetection,
      )
    }
  }

  /// Frequency-domain requirements including FFT and bucketing configuration.
  public struct FrequencyDomainWork: Sendable, Equatable {
    public enum ValidationError: Error, Sendable, Equatable, CustomStringConvertible {
      case peakHoldDecayRateMustBeNonNegative(actual: Float)

      public var description: String {
        switch self {
        case .peakHoldDecayRateMustBeNonNegative(let actual):
          "peakHoldDecayRate must be >= 0, got \(actual)"
        }
      }
    }

    public var configuration: FrequencyAnalyzer.Configuration
    public var bucketMode: FrequencyBucketMode
    public var peakHoldDecayRate: Float
    public var weighting: FrequencyWeighting

    public init(
      configuration: FrequencyAnalyzer.Configuration,
      bucketMode: FrequencyBucketMode = .default,
      peakHoldDecayRate: Float = 0.015,
      weighting: FrequencyWeighting = .none,
    ) {
      precondition(
        peakHoldDecayRate >= 0,
        "FrequencyDomainWork.peakHoldDecayRate must be >= 0, got \(peakHoldDecayRate)",
      )
      self.configuration = configuration
      self.bucketMode = bucketMode
      self.peakHoldDecayRate = peakHoldDecayRate
      self.weighting = weighting
    }

    public init(
      validatingConfiguration configuration: FrequencyAnalyzer.Configuration,
      bucketMode: FrequencyBucketMode = .default,
      peakHoldDecayRate: Float = 0.015,
      weighting: FrequencyWeighting = .none,
    ) throws(ValidationError) {
      guard peakHoldDecayRate >= 0 else {
        throw .peakHoldDecayRateMustBeNonNegative(actual: peakHoldDecayRate)
      }
      self.init(
        configuration: configuration,
        bucketMode: bucketMode,
        peakHoldDecayRate: peakHoldDecayRate,
        weighting: weighting,
      )
    }

    public init(
      clampingConfiguration configuration: FrequencyAnalyzer.Configuration,
      bucketMode: FrequencyBucketMode = .default,
      peakHoldDecayRate: Float = 0.015,
      weighting: FrequencyWeighting = .none,
    ) {
      self.init(
        configuration: configuration,
        bucketMode: bucketMode,
        peakHoldDecayRate: max(0, peakHoldDecayRate),
        weighting: weighting,
      )
    }
  }

#endif
