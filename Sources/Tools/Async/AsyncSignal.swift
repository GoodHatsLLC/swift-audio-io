// © GoodHatsLLC

import Foundation

public typealias AsyncSignalStream<Element: Sendable> = AsyncStream<Element>
public typealias AsyncSignalContinuation<Element: Sendable> = AsyncStream<Element>.Continuation

/// A small owned signal channel for coalesced wakeups and state-change events.
public final class AsyncSignal<Element: Sendable>: Sendable {
  private let stream: AsyncSignalStream<Element>
  private let continuation: AsyncSignalContinuation<Element>

  public init(
    bufferingPolicy: AsyncSignalContinuation<Element>.BufferingPolicy = .bufferingNewest(1)
  ) {
    let signal = AsyncSignalStream<Element>.makeStream(bufferingPolicy: bufferingPolicy)
    stream = signal.stream
    continuation = signal.continuation
  }

  public func events() -> AsyncSignalStream<Element> {
    stream
  }

  public func yield(_ element: Element) {
    continuation.yield(element)
  }

  public func finish() {
    continuation.finish()
  }
}

extension AsyncSignal where Element == Void {
  public func signal() {
    yield(())
  }
}
