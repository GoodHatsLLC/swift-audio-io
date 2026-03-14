// © GoodHatsLLC

#if canImport(AVFAudio)
  public import AudioSignals
  public import Foundation

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

  /// Work request submitted by a visualization subscriber.
  @safe public struct VisualizationRequest: Sendable, Equatable {
    public var work: VisualizationWork
    public var eventMask: VisualizationEventMask

    public init(
      work: VisualizationWork = .none,
      eventMask: VisualizationEventMask = .all,
    ) {
      self.work = work
      self.eventMask = eventMask
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

    public init(cancelHandler: @escaping @MainActor () -> Void) {
      self.cancelHandler = cancelHandler
    }

    public func cancel() {
      guard !isCancelled else { return }
      isCancelled = true
      cancelHandler()
    }
  }

  /// Minimal protocol surface needed by external waveform processing consumers.
  public protocol VisualizationDriving: AnyObject, Sendable {
    nonisolated var currentSampleRate: Double { get }
    nonisolated var currentTimeSeconds: TimeInterval { get }

    @MainActor
    func subscribe(
      request: VisualizationRequest,
      handler: @escaping @Sendable (VisualizationEvent) -> Void,
    ) -> VisualizationSubscription

    nonisolated func withCurrentLODSnapshotRef<R>(_ body: (LODSnapshotRef) -> R) -> R?
  }

#endif
