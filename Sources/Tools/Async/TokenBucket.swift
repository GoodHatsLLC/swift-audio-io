private import DequeModule

/// Type modelled after a "token bucket" pattern, which is similar to a semaphore, but is built with
/// Swift Concurrency primitives.
public actor TokenBucket {
  private var tokens: Int
  private var waiters: Deque<CheckedContinuation<Void, Never>>

  public init(tokens: Int) {
    self.tokens = tokens
    self.waiters = Deque()
  }

  /// Executes an `async` closure immediately when a token is available.
  /// Only the same number of closures will be executed concurrently as the number
  /// of `tokens` passed to ``TokenBucket/init(tokens:)``, all subsequent
  /// invocations of `withToken` will suspend until a "free" token is available.
  /// - Parameter body: The closure to invoke when a token is available.
  /// - Returns: Resulting value returned by `body`.
  public func withToken<ReturnType: Sendable>(
    _ body: @Sendable () async throws -> ReturnType
  ) async rethrows -> ReturnType {
    await self.getToken()
    defer {
      self.returnToken()
    }

    return try await body()
  }

  public func getToken() async {
    if self.tokens > 0 {
      self.tokens -= 1
      return
    }

    await withCheckedContinuation {
      self.waiters.append($0)
    }
  }

  public func returnToken() {
    if let nextWaiter = self.waiters.popFirst() {
      nextWaiter.resume()
    } else {
      self.tokens += 1
    }
  }
}
