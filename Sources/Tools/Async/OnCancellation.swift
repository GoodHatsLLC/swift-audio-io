public func onCancellationHandler<T: Sendable>(
  isolation: isolated (any Actor)? = #isolation,
  cleanup: () async -> T
) async -> T {
  let didCancel = AsyncContinuation<Void>()
  return await withTaskCancellationHandler(
    operation: {
      _ = await didCancel.result
      return await cleanup()
    },
    onCancel: {
      try? didCancel.yield(())
    },
    isolation: isolation
  )
}

public func onCancellationHandler<T: Sendable, Failure: AudioError>(
  isolation: isolated (any Actor)? = #isolation,
  cleanup: () async throws(Failure) -> T
) async throws(Failure) -> T {
  let didCancel = AsyncContinuation<Void>()
  do {
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
  } catch let error as Failure {
    throw error
  } catch {
    preconditionFailure("Unexpected error type: \(error)")
  }
}
