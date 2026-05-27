// © GoodHatsLLC

#if canImport(AVFAudio)
  public import AudioSignals
  public import Foundation

  // MARK: - Subscription

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
