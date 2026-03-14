// © GoodHatsLLC

import Foundation
import OrderedCollections
import Synchronization
import os

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, *)
public final class AsyncBroadcaster<Element: Sendable>: AsyncSequence, Sendable {
  public typealias Element = Element

  public init<S: AsyncSequence>(replay: AsyncBuffer, sequence: sending S)
  where S.Element == Element {
    let controller = MulticastController<Element>(
      sequence.map(MulticastController.Event.publish), replay: replay,
    )
    self.controller = controller
    memory = replay
  }

  let controller: MulticastController<Element>
  let memory: AsyncBuffer

  public func makeAsyncIterator() -> Iterator {
    let underlying = AsyncStream<Element>
      .makeStream(
        of: Element.self,
        bufferingPolicy: .unbounded,
      )
    controller.handle(.subscribe(underlying.continuation))
    return Iterator(underlying: underlying.stream.makeAsyncIterator())
  }

  public struct Iterator: AsyncIteratorProtocol {
    init(underlying: AsyncStream<Element>.Iterator) {
      self.underlying = underlying
    }

    private var underlying: AsyncStream<Element>.Iterator

    public mutating func next(isolation: isolated (any Actor)?) async
      -> Element?
    {
      await underlying.next(isolation: isolation)
    }
  }
}

extension AsyncSequence where Self: Sendable, Self.Element: Sendable {
  public func broadcast(replay: AsyncBuffer = .none) -> AsyncBroadcaster<Element> {
    AsyncBroadcaster(replay: replay, sequence: self)
  }
}

final class MulticastController<Element: Sendable>: Sendable {
  enum Event {
    case subscribe(_ continuation: AsyncStream<Element>.Continuation)
    case unsubscribe(id: UUID)
    case publish(Element)
    case finish
  }

  init<S: AsyncSequence>(
    isolation: isolated (any Actor)? = #isolation, _ sequence: S, replay: AsyncBuffer,
  ) where S.Element == Event {
    state = .init(.available(.init(replayCapacity: replay, replay: [], continuations: [:])))
    Task(priority: .high) { [weak self] in
      _ = isolation
      do {
        for try await event in sequence {
          guard let self else { return }
          handle(event)
        }
        self?.handle(.finish)
      } catch {
        self?.handle(.finish)
      }
    }
  }

  private let state: Mut<State>

  func handle(_ event: Event) {
    let action: @Sendable () -> Void = state.withLock { state in
      switch event {
      case .finish:
        state.finish()
        return {}
      case .subscribe(let continuation):
        let id = UUID()
        switch state {
        case .available(var storage):
          storage.continuations[id] = continuation
          state = .available(storage)
          storage.recite(to: continuation)
          return {
            continuation.onTermination = { [weak self] c in
              if let self {
                switch c {
                case .finished:
                  break
                case .cancelled:
                  handle(.unsubscribe(id: id))
                @unknown default:
                  break
                }
              }
            }
          }
        case .finished(let elements):
          for element in elements {
            continuation.yield(element)
          }
          continuation.finish()
          return {}
        }
      case .unsubscribe(let id):
        switch state {
        case .available(var storage):
          storage.finish(id: id)
          state = .available(storage)
        case .finished:
          break
        }
        return {}
      case .publish(let element):
        switch state {
        case .available(var storage):
          storage.remember(element)
          state = .available(storage)
          for (_, continuation) in storage.continuations {
            continuation.yield(element)
          }
        default: break
        }
        return {}
      }
    }
    action()
  }
}

extension MulticastController {
  enum State {
    struct InvalidTransition: AudioError {
      var description: String {
        "Invalid transition"
      }
    }

    case available(Storage)
    case finished([Element])

    mutating func finish() {
      switch self {
      case .finished:
        return
      case .available(var storage):
        storage.finishAll()
        self = .finished(storage.replay)
      }
    }
  }
}

extension MulticastController {
  struct Storage {
    let replayCapacity: AsyncBuffer
    var replay: [Element] = []
    var continuations: OrderedDictionary<UUID, AsyncStream<Element>.Continuation> = [:]
    mutating func finish(id: UUID) {
      if let continuation = continuations[id] {
        continuations[id] = nil
        continuation.finish()
      }
    }

    mutating func finishAll() {
      replay.removeAll()
      let continuations = continuations
      self.continuations.removeAll()
      for (_, continuation) in continuations {
        continuation.finish()
      }
    }

    mutating func remember(_ element: Element) {
      replay.append(element)
      replayCapacity.prune(elements: &replay)
    }

    func recite(to continuation: AsyncStream<Element>.Continuation) {
      for element in replay {
        continuation.yield(element)
      }
    }
  }
}

public enum AsyncBuffer: Sendable {
  case none
  case latest(Int)
  case unbounded

  public func prune(elements: inout [some Any]) {
    switch self {
    case .none:
      elements.removeAll()
    case .latest(let count):
      elements = elements.suffix(count)
    case .unbounded:
      break
    }
  }
}

extension AsyncStream.Continuation.BufferingPolicy {
  init(_ asyncBuffer: AsyncBuffer) {
    switch asyncBuffer {
    case .none:
      self = .bufferingNewest(0)
    case .latest(let count):
      self = .bufferingNewest(count)
    case .unbounded:
      self = .unbounded
    }
  }
}
