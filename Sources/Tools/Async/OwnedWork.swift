// © GoodHatsLLC

import Foundation

/// A detached task handle with both drained and best-effort cancellation APIs.
///
/// Use this for boundary work that must not inherit caller actor isolation, but
/// still needs an explicit owner that can await termination during shutdown.
public struct DetachedOwnedWork<Success: Sendable>: Sendable {
  private let task: Task<Success, Never>

  public init(
    priority: TaskPriority? = nil,
    operation: @Sendable @escaping () async -> Success
  ) {
    task = Task.detached(priority: priority) {
      await operation()
    }
  }

  public var isCancelled: Bool {
    task.isCancelled
  }

  public var value: Success {
    get async {
      await task.value
    }
  }

  public func cancelNow() {
    task.cancel()
  }

  public func cancel() async {
    task.cancel()
    _ = await task.value
  }
}

/// A main-actor task handle with both drained and best-effort cancellation APIs.
///
/// Use this for UI-owned work kicked off from synchronous view hooks when the
/// operation must remain main-actor isolated but still needs explicit ownership.
public struct MainActorOwnedWork: Sendable {
  private let task: Task<Void, Never>

  @MainActor
  public init(
    priority: TaskPriority? = nil,
    operation: @MainActor @Sendable @escaping () async -> Void
  ) {
    task = Task(priority: priority) {
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
