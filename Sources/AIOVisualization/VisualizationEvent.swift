// © GoodHatsLLC

#if canImport(AVFAudio)
  public import AIOContracts
  public import AudioSignals

  // MARK: - Visualization Events

  /// Stream event emitted by ``AudioVisualizationEngine``.
  @safe public enum VisualizationEvent: Sendable {
    case timeDomain(TimeDomainData)
    case frequencyDomain(FrequencyDomainData)
    case beat(BeatInfo)
    case lodSnapshot
    case lodSnapshotBackground
    case latestBufferTiming(BufferTiming?)
  }

  /// Per-subscriber filter for visualization event delivery.
  @safe public struct VisualizationEventMask: OptionSet, Sendable, Equatable, Hashable, Codable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
      self.rawValue = rawValue
    }

    public static let lodSnapshot = Self(rawValue: 1 << 0)
    public static let lodSnapshotBackground = Self(rawValue: 1 << 1)
    public static let timeDomain = Self(rawValue: 1 << 2)
    public static let frequencyDomain = Self(rawValue: 1 << 3)
    public static let beat = Self(rawValue: 1 << 4)
    public static let latestBufferTiming = Self(rawValue: 1 << 5)

    public static let all: Self = [
      .lodSnapshot,
      .lodSnapshotBackground,
      .timeDomain,
      .frequencyDomain,
      .beat,
      .latestBufferTiming,
    ]

    public static let none: Self = []
  }
#endif
