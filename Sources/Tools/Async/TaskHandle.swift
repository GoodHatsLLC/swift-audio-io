import Observation

/// A property wrapper which holds one `Task<Value, Never>` and cancels
/// it when a new value is set, or when it is deallocated.
@propertyWrapper
public struct TaskHandle<Value: Sendable>: Sendable {

  final class Box: Sendable {
    let value = Mut<Task<Value, Never>?>(nil)
    deinit {
      value.withLock { value in
        value
      }?
      .cancel()
    }
  }

  public init(
    _ type: Value.Type = Value.self,
    wrappedValue: Task<Value, Never>? = nil
  ) {
    self.wrappedValue = wrappedValue
  }

  private let box: Box = .init()
  private var boxedValue: Task<Value, Never>? {
    get {
      box.value.withLock { $0 }
    }
    nonmutating set {
      box.value.withLock { value in
        value = newValue
      }
    }
  }
  public var wrappedValue: Task<Value, Never>? {
    get {
      boxedValue
    }
    nonmutating set {
      if let boxedValue, boxedValue != newValue {
        boxedValue.cancel()
      }
      boxedValue = newValue
    }
  }
  public var projectedValue: TaskBuilder<Value> {
    TaskBuilder<Value> {
      wrappedValue = $0
    }
  }
}

public struct TaskBuilder<Value: Sendable>: Sendable {

  let sink: @Sendable (Task<Value, Never>) -> Void

  public func start(
    priority: TaskPriority? = nil,
    operation: sending @escaping @isolated(any) () async -> Value
  ) {
    sink(Task<Value, Never>(priority: priority, operation: operation))
  }

}
