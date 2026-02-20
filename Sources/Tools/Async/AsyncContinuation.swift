public import Foundation
import Synchronization

/// A value `Value` which will eventually be resolved for access.
///
/// This type wraps `withCheckedContinuation` but throws on repeated
/// yield rather than crashing.
///
/// - Tip: When possible, use `withCheckedContinuation` instead.
public final class AsyncContinuation<Value: Sendable>: Sendable {
  // MARK: Lifecycle

  public init() {}

  //  deinit {
  //    let pendingWaiterCount = continuations.withLock { state in
  //      switch state {
  //      case .yielded:
  //        0
  //      case .awaiting(let waiters):
  //        waiters.count
  //      }
  //    }
  //    precondition(
  //      pendingWaiterCount == 0,
  //      "AsyncContinuation<\(Value.self)> deinitialized with \(pendingWaiterCount) pending waiter(s)."
  //    )
  //  }

  // MARK: Public

  public typealias Failure = Never
  public struct AlreadyYielded: AudioError, Hashable {
    public let id: UUID
    public let yieldedValueDescription: String

    public var description: String {
      "AsyncContinuation<\(Value.self)> already yielded '\(yieldedValueDescription)'"
    }
  }

  public let id: UUID = .init()

  public static func == (lhs: borrowing AsyncContinuation, rhs: borrowing AsyncContinuation) -> Bool
  {
    lhs.id == rhs.id
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  @discardableResult
  public func callAsFunction() async -> Value {
    await withCheckedContinuation { continuation in
      let immediateValue = continuations.withLock { state -> Value? in
        switch state {
        case .yielded(let yielded):
          return yielded
        case .awaiting(var waiters):
          waiters.append(continuation)
          state = .awaiting(waiters)
          return nil
        }
      }
      if let immediateValue {
        continuation.resume(returning: immediateValue)
      }
    }
  }

  /// Yield a value for the continuation to return when awaited.
  ///
  /// - parameter value: The value that will be returned when the continuation called and awaited.
  /// - throws: The continuation's value can only be yielded once. Subsequent attempts will throw.
  public nonisolated func yield(_ value: Value) throws(AlreadyYielded) {
    let continuations = try continuations.withLock { state throws(AlreadyYielded) in
      switch state {
      case .yielded(let value):
        throw AlreadyYielded(id: id, yieldedValueDescription: String(describing: value))
      case .awaiting(let array):
        state = .yielded(value)
        return array
      }
    }
    for continuation in continuations {
      continuation.resume(returning: value)
    }
  }

  // MARK: Internal

  enum State {
    case yielded(Value)
    case awaiting([CheckedContinuation<Value, Never>])
  }

  let continuations: Mutex<State> = .init(.awaiting([]))
}

extension AsyncContinuation where Value == Void {
  public func yield() throws(AlreadyYielded) { try yield(()) }
}

extension AsyncContinuation {
  public var result: Result<Value, Never> {
    get async {
      await .success(self())
    }
  }
}

extension AsyncContinuation.AlreadyYielded {
  public var informativeDescription: String {
    description
  }
}
