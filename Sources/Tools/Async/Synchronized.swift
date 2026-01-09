@dynamicMemberLookup
public final class Synchronized<Value>: Sendable {
  public init(_ value: consuming sending Value) {
    self.mut = .init(value)
  }

  private let mut: Mut<Value>

  public borrowing func withLock<Result>(
    _ body: (inout sending Value) -> sending Result
  ) -> sending Result {
    mut.withLock(body)
  }

  public borrowing func withLock<Result, E>(
    _ body: (inout sending Value) throws(E) -> sending Result
  ) throws(E) -> sending Result where E: AudioError {
    try mut.withLock(body)
  }

  @discardableResult
  public nonisolated func callAsFunction<T>(_ action: (inout Value) -> T) -> T {
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

  public nonisolated subscript<T: Sendable>(dynamicMember keyPath: WritableKeyPath<Value, T>) -> T {
    get { pick(keyPath) }
    set { place(keyPath, value: newValue) }
  }

  public nonisolated subscript<T: Sendable>(dynamicMember keyPath: KeyPath<Value, T>) -> T {
    get { pick(keyPath) }
  }

  consuming public func consume<T: Sendable>(_ path: consuming WritableKeyPath<Value, T?>) -> T? {
    self { state in
      defer { state[keyPath: path] = nil }
      return state[keyPath: path]
    }
  }
}
