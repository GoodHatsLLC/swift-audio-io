public final class Subject<T: Sendable>: Sendable {
  let cont: AsyncStream<T>.Continuation
  let _broadcaster: AsyncBroadcaster<T>
  public init() {
    let (stream, cont) = AsyncStream<T>.makeStream()
    self._broadcaster = stream.broadcast()
    self.cont = cont
  }

  public var broadcaster: AsyncBroadcaster<T> {
    _broadcaster
  }

  public nonisolated func send(_ input: T) {
    cont.yield(input)
  }
}
