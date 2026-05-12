// © GoodHatsLLC

public import Foundation
import Synchronization

/// A throwing one-shot async value for callback bridges.
///
/// This wraps a checked throwing continuation, but repeated completion attempts
/// throw instead of trapping. Use it at framework callback boundaries where
/// success, failure, and fallback completion paths can race.
public final class AsyncThrowingContinuation<Value: Sendable>: Sendable {
  public init() {}

  public struct AlreadyResolved: Error, Hashable {
    public let id: UUID
    public let resolvedValueDescription: String

    public var description: String {
      "AsyncThrowingContinuation<\(Value.self)> already resolved '\(resolvedValueDescription)'"
    }
  }

  public let id: UUID = .init()

  @discardableResult
  public func callAsFunction() async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      let immediateResult = continuations.withLock { state -> Result<Value, any Error>? in
        switch state {
        case .resolved(let result):
          return result
        case .awaiting(var waiters):
          waiters.append(continuation)
          state = .awaiting(waiters)
          return nil
        }
      }
      if let immediateResult {
        continuation.resume(with: immediateResult)
      }
    }
  }

  public nonisolated func yield(_ value: Value) throws(AlreadyResolved) {
    try resolve(.success(value))
  }

  public nonisolated func fail(_ error: any Error) throws(AlreadyResolved) {
    try resolve(.failure(error))
  }

  private func resolve(_ result: Result<Value, any Error>) throws(AlreadyResolved) {
    let waiters = try continuations.withLock { state throws(AlreadyResolved) in
      switch state {
      case .resolved(let previous):
        throw AlreadyResolved(id: id, resolvedValueDescription: String(describing: previous))
      case .awaiting(let waiters):
        state = .resolved(result)
        return waiters
      }
    }
    for continuation in waiters {
      continuation.resume(with: result)
    }
  }

  private enum State {
    case resolved(Result<Value, any Error>)
    case awaiting([CheckedContinuation<Value, any Error>])
  }

  private let continuations: Mutex<State> = .init(.awaiting([]))
}

extension AsyncThrowingContinuation where Value == Void {
  public func yield() throws(AlreadyResolved) {
    try yield(())
  }
}
