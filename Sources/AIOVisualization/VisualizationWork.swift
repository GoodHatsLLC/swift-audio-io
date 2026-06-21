// © GoodHatsLLC

#if canImport(AVFAudio)
  public import AudioSignals

  // MARK: - Visualization Work Registration

  /// Declarative work specification for visualization pipelines.
  ///
  /// A ``VisualizationWork`` value declares the subset of computations a
  /// subscriber needs from ``AudioVisualizationEngine``: optional LOD
  /// processing for waveform rendering and/or optional analysis for
  /// time-domain, frequency-domain, and beat data. Work demand is resolved
  /// as the union of all active subscribers' requests.
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
      self.configuration = configuration
      self.publishRateHz = Self.clampedPositive(publishRateHz)
    }

    public init(
      validatingConfiguration configuration: MultiBandLODConfiguration,
      publishRateHz: Double = VisualizationRateDefaults.lodPublishRateHz,
    ) throws(ValidationError) {
      guard publishRateHz > 0 else {
        throw .publishRateMustBePositive(actual: publishRateHz)
      }
      self.configuration = configuration
      self.publishRateHz = publishRateHz
    }

    public init(
      clampingConfiguration configuration: MultiBandLODConfiguration,
      publishRateHz: Double = VisualizationRateDefaults.lodPublishRateHz,
    ) {
      self.init(
        configuration: configuration,
        publishRateHz: publishRateHz,
      )
    }

    private static func clampedPositive(_ value: Double) -> Double {
      guard value.isFinite else { return 1 }
      return max(1, value)
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
      self.updateRateHz = Self.clampedPositive(updateRateHz)
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
      self.updateRateHz = updateRateHz
      self.timeDomain = timeDomain
      self.frequencyDomain = frequencyDomain
      self.beatDetection = beatDetection
    }

    public init(
      clampingUpdateRateHz updateRateHz: Double,
      timeDomain: AmplitudeAnalyzer.Configuration? = nil,
      frequencyDomain: FrequencyDomainWork? = nil,
      beatDetection: BeatDetectionConfiguration? = nil,
    ) {
      self.init(
        updateRateHz: updateRateHz,
        timeDomain: timeDomain,
        frequencyDomain: frequencyDomain,
        beatDetection: beatDetection,
      )
    }

    private static func clampedPositive(_ value: Double) -> Double {
      guard value.isFinite else { return 1 }
      return max(1, value)
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
      self.configuration = configuration
      self.bucketMode = bucketMode
      self.peakHoldDecayRate = Self.clampedNonNegative(peakHoldDecayRate)
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
      self.configuration = configuration
      self.bucketMode = bucketMode
      self.peakHoldDecayRate = peakHoldDecayRate
      self.weighting = weighting
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
        peakHoldDecayRate: peakHoldDecayRate,
        weighting: weighting,
      )
    }

    private static func clampedNonNegative(_ value: Float) -> Float {
      guard value.isFinite else { return 0 }
      return max(0, value)
    }
  }

#endif
