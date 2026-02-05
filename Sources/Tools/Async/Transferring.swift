public struct Transferring<T>: @unchecked Sendable {
  public let value: T

  public init(_ value: consuming T) {
    self.value = value
  }
}
