// © GoodHatsLLC

import Foundation

/// A detached task handle with both drained and best-effort cancellation APIs.
///
/// Use this for boundary work that must not inherit caller actor isolation, but
/// still needs an explicit owner that can await termination during shutdown.
public struct DetachedOwnedTask: Sendable {
  private let task: Task<Void, Never>

  public init(
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async -> Void
  ) {
    task = Task.detached(priority: priority) {
      await operation()
    }
  }

  public var isCancelled: Bool {
    task.isCancelled
  }

  public var value: Void {
    get async {
      await task.value
    }
  }

  public func cancelNow() {
    task.cancel()
  }

  public func cancel() async {
    task.cancel()
    await task.value
  }
}
