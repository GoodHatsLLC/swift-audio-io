#if canImport(AVFAudio)
  public import AudioSignals

  // MARK: - Visualization Sinks & Consumer

  /// Sink callbacks for visualization outputs.
  @safe public struct VisualizationSinks: Sendable {
    public var timeDomain: (@MainActor (TimeDomainData) -> Void)?
    public var frequencyDomain: (@MainActor (FrequencyDomainData) -> Void)?
    public var beat: (@MainActor (BeatInfo) -> Void)?
    public var lodSnapshot: (@MainActor (LODSnapshotRef?) -> Void)?
    public var lodSnapshotBackground: (@Sendable (LODSnapshotRef?) -> Void)?
    public var latestBufferTiming: (@MainActor (BufferTiming?) -> Void)?

    public init(
      timeDomain: (@MainActor (TimeDomainData) -> Void)? = nil,
      frequencyDomain: (@MainActor (FrequencyDomainData) -> Void)? = nil,
      beat: (@MainActor (BeatInfo) -> Void)? = nil,
      lodSnapshot: (@MainActor (LODSnapshotRef?) -> Void)? = nil,
      lodSnapshotBackground: (@Sendable (LODSnapshotRef?) -> Void)? = nil,
      latestBufferTiming: (@MainActor (BufferTiming?) -> Void)? = nil
    ) {
      self.timeDomain = timeDomain
      self.frequencyDomain = frequencyDomain
      self.beat = beat
      self.lodSnapshot = lodSnapshot
      self.lodSnapshotBackground = lodSnapshotBackground
      self.latestBufferTiming = latestBufferTiming
    }

    public static let empty = VisualizationSinks()
  }

  /// A consumer that declares required work and exposes sinks for updates.
  @MainActor
  public protocol VisualizationConsumer: AnyObject {
    var work: VisualizationWork { get }
    var sinks: VisualizationSinks { get }
  }

#endif
