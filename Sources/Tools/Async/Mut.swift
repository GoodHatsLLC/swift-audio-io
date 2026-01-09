#if canImport(Synchronization)
  import Synchronization
#else
  import os
#endif

public struct Mut<Value>: Sendable, ~Copyable {
  #if canImport(Synchronization)
    let lock: Mutex<Value>
  #else
    let lock: OSAllocatedUnfairLock<Value>
  #endif
}

extension Mut {
  public init(_ initialValue: consuming sending Value) {
    #if canImport(Synchronization)
      self.lock = Mutex(initialValue)
    #else
      self.lock = OSAllocatedUnfairLock(uncheckedState: initialValue)
    #endif
  }

  public borrowing func withLock<Result>(
    _ body: (inout sending Value) -> sending Result
  ) -> sending Result {
    #if canImport(Synchronization)
      return lock.withLock { (v) -> Transferring<Result> in
        nonisolated(unsafe) var copy = v
        defer { v = copy }
        return Transferring(body(&copy))
      }.value
    #else
      return lock.withLockUnchecked { (v) -> Transferring<Result> in
        nonisolated(unsafe) var copy = v
        defer { v = copy }
        return Transferring(body(&copy))
      }.value
    #endif
  }

  public borrowing func withLock<Result, E>(
    _ body: (inout sending Value) throws(E) -> sending Result
  ) throws(E) -> sending Result where E: TypedThrowsError {
    do {
      #if canImport(Synchronization)
        return try lock.withLock { (v) -> Transferring<Result> in
          nonisolated(unsafe) var copy = v
          defer { v = copy }
          return try Transferring(body(&copy))
        }.value
      #else
        return try lock.withLockUnchecked { (v) -> Transferring<Result> in
          nonisolated(unsafe) var copy = v
          defer { v = copy }
          return try Transferring(body(&copy))
        }.value
      #endif
    } catch let error as E {
      throw error
    } catch {
      preconditionFailure("cannot occur")
    }
  }

  public borrowing func withLockIfAvailable<Result>(
    _ body: (inout sending Value) -> sending Result
  ) -> sending Result? {
    #if canImport(Synchronization)
      return lock.withLockIfAvailable { (v) -> Transferring<Result> in
        nonisolated(unsafe) var copy = v
        defer { v = copy }
        return Transferring(body(&copy))
      }?.value
    #else
      return lock.withLockIfAvailableUnchecked { (v) -> Transferring<Result> in
        nonisolated(unsafe) var copy = v
        defer { v = copy }
        return Transferring(body(&copy))
      }?.value
    #endif
  }

  public borrowing func withLockIfAvailable<Result, E>(
    _ body: (inout sending Value) throws(E) -> sending Result
  ) throws(E) -> sending Result? where E: TypedThrowsError {
    do {
      #if canImport(Synchronization)
        return try lock.withLockIfAvailable { (v) -> Transferring<Result> in
          nonisolated(unsafe) var copy = v
          defer { v = copy }
          return try Transferring(body(&copy))
        }?.value
      #else
        return try lock.withLockIfAvailableUnchecked { (v) -> Transferring<Result> in
          nonisolated(unsafe) var copy = v
          defer { v = copy }
          return try Transferring(body(&copy))
        }?.value
      #endif
    } catch let error as E {
      throw error
    } catch {
      preconditionFailure("cannot occur")
    }
  }
}
