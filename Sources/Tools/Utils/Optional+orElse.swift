extension Optional {
  package func orElse(_ transform: @autoclosure () -> Wrapped) -> Wrapped {
    self ?? transform()
  }
  package struct MissingWrappedValue<T>: AudioError {
    package init() {}

    package var description: String {
      "Missing wrapped value for Optional<\(T.self)>"
    }
  }
  package func orThrow() throws(MissingWrappedValue<Wrapped>) -> Wrapped {
    if let value = self {
      return value
    } else {
      throw MissingWrappedValue<Wrapped>()
    }
  }
}
