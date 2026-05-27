// © GoodHatsLLC

import Foundation

final class VisualizationDispatchTicker {
  private let queue: DispatchQueue
  private var source: (any DispatchSourceTimer)?

  init(label: String, qos: DispatchQoS) {
    queue = DispatchQueue(label: label, qos: qos)
  }

  deinit {
    cancel()
  }

  func syncBarrier() {
    queue.sync {}
  }

  func start(
    interval: TimeInterval,
    leeway: DispatchTimeInterval? = nil,
    handler: @escaping () -> Void
  ) {
    cancel()

    let nextSource = DispatchSource.makeTimerSource(queue: queue)
    if let leeway {
      nextSource.schedule(deadline: .now(), repeating: interval, leeway: leeway)
    } else {
      nextSource.schedule(deadline: .now(), repeating: interval)
    }
    nextSource.setEventHandler(handler: handler)
    nextSource.resume()
    source = nextSource
  }

  func cancel() {
    source?.cancel()
    source = nil
  }
}
