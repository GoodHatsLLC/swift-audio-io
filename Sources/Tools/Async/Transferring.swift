// SAFETY: Ownership-transfer wrapper — value is consumed at init and must not be accessed
// from the original context after transfer.
public struct Transferring<T>: @unchecked Sendable {
  public let value: T

  public init(_ value: consuming T) {
    self.value = value
  }
}
