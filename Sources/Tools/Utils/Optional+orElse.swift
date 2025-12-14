extension Optional {
  public func orElse(_ transform: @autoclosure () -> Wrapped) -> Wrapped {
    self ?? transform()
  }
  public struct MissingWrappedValue<T>: Error {}
  public func orThrow() throws(MissingWrappedValue<Wrapped>) -> Wrapped {
    if let value = self {
      return value
    } else {
      throw MissingWrappedValue<Wrapped>()
    }
  }
}
