public func OnCancellationHandler<T: Sendable>(
  isolation: isolated (any Actor)? = #isolation,
  cleanup: () async throws -> T
) async rethrows -> T {
  let didCancel = AsyncContinuation<Void>()
  return try await withTaskCancellationHandler(
    operation: {
      _ = await didCancel.result
      return try await cleanup()
    },
    onCancel: {
      try? didCancel.yield(())
    },
    isolation: isolation
  )
}
