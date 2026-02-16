public final class Synchronized<Value>: Sendable {
  public init(_ value: consuming sending Value) {
    self.mut = .init(value)
  }

  private let mut: Mut<Value>

  public nonisolated borrowing func withLock<Result, E>(
    _ body: (inout Value) throws(E) -> sending Result
  ) throws(E) -> sending Result {
    try mut.withLock(body)
  }

  /// Attempts to acquire the lock without blocking. Returns `nil` if the lock
  /// is currently held by another thread.
  ///
  /// This is useful on latency-sensitive threads (e.g. audio tap callbacks)
  /// where blocking on a contended lock could cause jitter.
  public nonisolated borrowing func withLock<Result, E>(
    ifAvailable body: (inout Value) throws(E) -> sending Result
  ) throws(E) -> sending Result? {
    try mut.withLockIfAvailable(body)
  }

  @discardableResult
  public nonisolated func callAsFunction<T>(_ action: (inout Value) -> sending T) -> sending T {
    withLock { state in
      var s = state
      let it = action(&s)
      state = s
      return it
    }
  }
  private nonisolated func place<T: Sendable>(_ path: consuming WritableKeyPath<Value, T>, value: T)
  {
    self { [value] s in
      s[keyPath: path] = value
    }
  }
  private nonisolated func pick<T: Sendable>(_ path: consuming KeyPath<Value, T>) -> T {
    withLock(\.self)[keyPath: path]
  }

  public nonisolated subscript<T: Sendable>(locked keyPath: WritableKeyPath<Value, T>) -> T {
    get { pick(keyPath) }
    set { place(keyPath, value: newValue) }
  }

  consuming public func consume<T: Sendable>(_ path: consuming WritableKeyPath<Value, T?>) -> T? {
    self { state in
      defer { state[keyPath: path] = nil }
      return state[keyPath: path]
    }
  }
}
