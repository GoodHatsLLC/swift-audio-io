// © GoodHatsLLC

import Foundation

@MainActor
final class AudioEnvironmentEventHub {
  typealias Handler = @Sendable @MainActor (AudioSystemEvent) async -> Void

  private var subscribers: [UUID: Handler] = [:]

  @discardableResult
  func addSubscriber(_ handler: @escaping Handler) -> UUID {
    let id = UUID()
    subscribers[id] = handler
    return id
  }

  func removeSubscriber(_ id: UUID) {
    subscribers.removeValue(forKey: id)
  }

  func dispatch(_ event: AudioSystemEvent) async {
    let subscriberSnapshot = Array(subscribers.values)
    for subscriber in subscriberSnapshot {
      await subscriber(event)
    }
  }
}
