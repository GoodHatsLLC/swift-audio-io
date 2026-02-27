#if canImport(AVFAudio)
  import Foundation
  public import AudioSignals

  // MARK: - Visualization Events & Subscription

  /// Stream event emitted by ``AudioVisualizationEngine``.
  @safe public enum VisualizationEvent: Sendable {
    case timeDomain(TimeDomainData)
    case frequencyDomain(FrequencyDomainData)
    case beat(BeatInfo)
    case lodSnapshot(LODSnapshotRef?)
    case lodSnapshotBackground(LODSnapshotRef?)
    case latestBufferTiming(BufferTiming?)
  }

  /// Work request submitted by a visualization subscriber.
  @safe public struct VisualizationRequest: Sendable, Equatable {
    public var work: VisualizationWork

    public init(work: VisualizationWork = .none) {
      self.work = work
    }
  }

  /// Event sink protocol for the subscription API.
  @MainActor
  public protocol VisualizationSink: AnyObject, Sendable {
    func receive(_ event: VisualizationEvent)
  }

  /// A cancellable visualization subscription.
  @MainActor
  public final class VisualizationSubscription {
    private var isCancelled = false
    private let cancelHandler: @MainActor () -> Void

    init(cancelHandler: @escaping @MainActor () -> Void) {
      self.cancelHandler = cancelHandler
    }

    public func cancel() {
      guard !isCancelled else { return }
      isCancelled = true
      cancelHandler()
    }
  }

  // MARK: - Visualization Sinks

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

    /// Creates a sink bundle that forwards every callback as a ``VisualizationEvent``.
    public static func eventForwarding(
      _ handler: @escaping @Sendable (VisualizationEvent) -> Void
    ) -> VisualizationSinks {
      VisualizationSinks(
        timeDomain: { handler(.timeDomain($0)) },
        frequencyDomain: { handler(.frequencyDomain($0)) },
        beat: { handler(.beat($0)) },
        lodSnapshot: { handler(.lodSnapshot($0)) },
        lodSnapshotBackground: { handler(.lodSnapshotBackground($0)) },
        latestBufferTiming: { handler(.latestBufferTiming($0)) }
      )
    }
  }

#endif
