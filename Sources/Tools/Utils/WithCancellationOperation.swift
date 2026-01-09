import Foundation

/// Suspend until the current task context is cancelled, then execute the operation.
public func withCancellationOperation<T: Sendable>(
  isolation: isolated (any Actor)? = #isolation,
  operation: () async -> T
) async -> T {
  let didCancel = AwaitableBox<Void>()
  return await withTaskCancellationHandler(
    operation: {
      _ = await didCancel()
      return await operation()
    },
    onCancel: {
      try? didCancel.yield(())
    },
    isolation: isolation
  )
}

/// Suspend until the current task context is cancelled, then execute the operation.
public func withCancellationOperation<T: Sendable, Failure: TypedThrowsError>(
  isolation: isolated (any Actor)? = #isolation,
  operation: () async throws(Failure) -> T
) async throws(Failure) -> T {
  let didCancel = AwaitableBox<Void>()
  do {
    return try await withTaskCancellationHandler(
      operation: {
        _ = await didCancel()
        return try await operation()
      },
      onCancel: {
        try? didCancel.yield(())
      },
      isolation: isolation
    )
  } catch let error as Failure {
    throw error
  } catch {
    preconditionFailure("Unexpected error type: \(error)")
  }
}

/// An eventual value, whose availability can be awaited.
///
/// - Can be awaited by multiple callers.
/// - Only one value can be yielded.
public final class AwaitableBox<Value: Sendable>: Identifiable, Hashable, Sendable {
  // MARK: Lifecycle

  public init() {}

  // MARK: Public

  public typealias Failure = Never
  public struct AlreadyYielded: TypedThrowsError, Hashable {
    public let id: UUID
    public let yieldedValueDescription: String

    public var description: String {
      "AwaitableBox<\(Value.self)> already yielded '\(yieldedValueDescription)'"
    }
  }

  public let id: UUID = .init()

  public static func == (lhs: AwaitableBox, rhs: AwaitableBox) -> Bool {
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

  let continuations: Mut<State> = .init(.awaiting([]))
}

extension AwaitableBox where Value == Void {
  public func yield() throws(AlreadyYielded) { try yield(()) }
}
