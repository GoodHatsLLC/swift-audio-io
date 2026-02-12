// SAFETY: Value is consumed at init and only exposed through this wrapper after transfer.
public struct Transferring<T>: @unchecked Sendable {
  public let value: T

  public init(_ value: consuming T) {
    self.value = value
  }
}
