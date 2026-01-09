extension Optional {
  public func orElse(_ transform: @autoclosure () -> Wrapped) -> Wrapped {
    self ?? transform()
  }
  public struct MissingWrappedValue<T>: TypedThrowsError {
    public init() {}

    public var description: String {
      "Missing wrapped value for Optional<\(T.self)>"
    }
  }
  public func orThrow() throws(MissingWrappedValue<Wrapped>) -> Wrapped {
    if let value = self {
      return value
    } else {
      throw MissingWrappedValue<Wrapped>()
    }
  }
}
