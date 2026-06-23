// © GoodHatsLLC

/// Serializes asynchronous work so submitted jobs run strictly **one at a time,
/// in submission (FIFO) order**, on a single long-lived consumer task that is
/// detached from any caller's actor.
///
/// This is the correct primitive for serializing *non-interruptible* blocking
/// work — e.g. the synchronous `AVAudioSession` `setPreferred*` XPC round-trips
/// behind the audio input-preference setters — where a cancel-on-set /
/// replacing-slot scheme is insufficient. Cancellation only *flags* a `Task`; it
/// cannot interrupt an in-flight synchronous call, so two overlapping
/// submissions would still both reach the hardware and race. A serial queue
/// guarantees the underlying work never overlaps and that ordered state
/// write-backs land in submission order.
///
/// Two submission styles share the same FIFO order:
/// - ``enqueue(_:)`` — fire-and-forget; returns immediately. For synchronous
///   call sites (e.g. SwiftUI bindable setters) that cannot `await`.
/// - ``submit(_:)`` — suspends until *this* job finishes. For async callers that
///   need the work to have landed before continuing.
///
/// Because both share one FIFO, a fire-and-forget ``enqueue(_:)`` issued before
/// an awaited ``submit(_:)`` is guaranteed to have completed by the time the
/// `submit` returns.
///
/// - Note: The consumer is created with `Task.detached`, so under
///   `NonisolatedNonsendingByDefault` (SE-0461) awaited jobs run on the global
///   concurrent executor, **not** the actor that created the queue. See
///   `ExecutorContractTests`.
public final class SerialAsyncWorkQueue: Sendable {
  public typealias Job = @Sendable () async -> Void

  private let continuation: AsyncStream<Job>.Continuation
  private let consumer: Task<Void, Never>

  public init() {
    let (stream, continuation) = AsyncStream<Job>.makeStream(bufferingPolicy: .unbounded)
    self.continuation = continuation
    // `Task.detached` runs the consumer on the global concurrent executor rather
    // than inheriting the creating actor (which would put blocking jobs back on,
    // e.g., the main actor under SE-0461). Jobs awaited here therefore execute
    // off the creating actor; a job may still explicitly hop with `MainActor.run`.
    consumer = Task.detached {
      for await job in stream {
        await job()
      }
    }
  }

  /// Submits work without waiting for it to run. Ordered after every prior
  /// submission. Dropped silently if the queue has been ``finish()``ed.
  public func enqueue(_ job: @escaping Job) {
    continuation.yield(job)
  }

  /// Submits work and suspends until it has finished running.
  ///
  /// If the queue has already been ``finish()``ed the job is not run and this
  /// returns immediately, mirroring iteration over a terminated stream.
  public func submit(_ job: @escaping Job) async {
    await withCheckedContinuation { (signal: CheckedContinuation<Void, Never>) in
      let result = continuation.yield {
        await job()
        signal.resume()
      }
      switch result {
      case .enqueued:
        break  // the buffered job resumes `signal` when it runs
      case .dropped, .terminated:
        signal.resume()
      @unknown default:
        signal.resume()
      }
    }
  }

  /// Submits work, suspends until it finishes, and returns its result.
  ///
  /// Returns `nil` (without running `job`) if the queue has already been
  /// ``finish()``ed.
  public func submit<T: Sendable>(_ job: @escaping @Sendable () async -> T) async -> T? {
    await withCheckedContinuation { (signal: CheckedContinuation<T?, Never>) in
      let result = continuation.yield {
        let value = await job()
        signal.resume(returning: value)
      }
      switch result {
      case .enqueued:
        break
      case .dropped, .terminated:
        signal.resume(returning: nil)
      @unknown default:
        signal.resume(returning: nil)
      }
    }
  }

  /// Ends the queue. Jobs already buffered still run to completion; further
  /// submissions are dropped. The consumer task is **not** cancelled, so awaiters
  /// of already-buffered jobs never hang.
  public func finish() {
    continuation.finish()
  }

  deinit {
    continuation.finish()
  }
}
