// © GoodHatsLLC

import Dispatch

/// Serializes direct `AVAudioSession` access across AudioIO's environment and
/// engine layers.
///
/// `AVAudioSession` is process-global. AudioIO has two legitimate owners of it:
/// `AudioEnvironmentManager` mirrors route/input state for UI, while
/// `AIOEngine` configures and starts capture. Route notifications can arrive
/// while capture is being brought up, especially around Bluetooth devices. This
/// gate keeps synchronous session reads/writes and engine start from overlapping
/// in those windows.
package enum AudioSessionAccess {
  private static let queue = DispatchQueue(
    label: "AudioIO.audio-session-access", qos: .userInitiated)

  package static func sync<T>(_ body: () -> T) -> T {
    queue.sync(execute: body)
  }

  package static func result<T, E: Error>(
    catching _: E.Type,
    _ body: () throws(E) -> T,
  ) -> Result<T, E> {
    queue.sync {
      do {
        return .success(try body())
      } catch let error as E {
        return .failure(error)
      } catch {
        preconditionFailure("Typed throws produced unexpected error type: \(error)")
      }
    }
  }

  package static func throwing<T>(_ body: () throws -> T) throws -> T {
    let outcome: Result<T, any Error> = queue.sync {
      Result {
        try body()
      }
    }
    return try outcome.get()
  }

  package static func async<T: Sendable>(
    _ body: @escaping @Sendable () -> T,
  ) async -> T {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: body())
      }
    }
  }

  package static func result<T: Sendable, E: Error & Sendable>(
    catching _: E.Type,
    _ body: @escaping @Sendable () throws(E) -> T,
  ) async -> Result<T, E> {
    await withCheckedContinuation { continuation in
      queue.async {
        do {
          continuation.resume(returning: .success(try body()))
        } catch let error as E {
          continuation.resume(returning: .failure(error))
        } catch {
          preconditionFailure("Typed throws produced unexpected error type: \(error)")
        }
      }
    }
  }
}
