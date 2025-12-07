public struct Transferring<T>: Sendable {
  public nonisolated(unsafe) var value: T

  public init(_ value: T) {
    self.value = value
  }
}
