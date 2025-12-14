import Foundation
import Synchronization

/// A value `Value` which will eventually be resolved for access.
///
/// This type wraps `withCheckedContinuation` but throws on repeated
/// yield rather than crashing.
///
/// - Tip: When possible, use `withCheckedContinuation` instead.
public struct AsyncContinuation<Value: Sendable>: Sendable, ~Copyable {
  // MARK: Lifecycle

  public init() {}

  // MARK: Public

  public typealias Failure = Never
  public struct AlreadyYielded: Error {
    public let id: UUID
    public let value: Value
  }

  public let id: UUID = .init()

  public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
    lhs.id == rhs.id
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  @discardableResult
  public func callAsFunction() async -> Value {
    await withCheckedContinuation { c in
      continuations.withLock { state in
        switch state {
        case .yielded(let t):
          c.resume(returning: t)
        case .awaiting(let others):
          state = .awaiting(others + [c])
        }
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
        throw AlreadyYielded(id: id, value: value)
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
  public func yield() throws { try yield(()) }
}

extension AsyncContinuation {
  public var result: Result<Value, Never> {
    get async {
      await .success(self())
    }
  }
}

extension AsyncContinuation.AlreadyYielded: Sendable {
  public var informativeDescription: String {
    "The result already yielded as \(String(describing: value))"
  }
}

extension AsyncContinuation.AlreadyYielded: Equatable where Value: Equatable {}
extension AsyncContinuation.AlreadyYielded: Hashable where Value: Hashable {}
