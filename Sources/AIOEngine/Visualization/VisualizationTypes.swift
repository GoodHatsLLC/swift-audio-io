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

#endif
