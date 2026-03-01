/// A property wrapper which holds one `Task<Success, Failure>` and cancels
/// it when a new value is set, or when it is deallocated.
@propertyWrapper public struct TaskHolder<Success: Sendable, Failure: Error>: ~Copyable {
  public init(
    success: Success.Type = Success.self, failure: Failure.Type = Failure.self,
    wrappedValue: Task<Success, Failure>? = nil
  ) {
    self.wrappedValue = wrappedValue
  }

  deinit {
    wrappedValue?.cancel()
  }

  public var wrappedValue: Task<Success, Failure>? = nil {
    willSet {
      wrappedValue?.cancel()
    }
  }
}
