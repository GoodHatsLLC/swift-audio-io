import AsyncAlgorithms
import Foundation

/// Type erasure of async sequences with a failure type.
///
/// - Note: Relies fully on the upstream sequence for buffer control.
extension AsyncThrowingStream where Failure == any Error {

  /// Type erasure of a failable async sequence. (iOS 17 compatible)
  ///
  /// - Note: Relies fully on the upstream sequence for buffer control.
  public init<S: AsyncSequence>(isolation: isolated (any Actor)? = #isolation, _ source: S)
  where S.Element == Element {
    let (stream, cont) = AsyncThrowingStream.makeStream()

    self = stream
    let it = Task {
      _ = isolation
      var iter = source.makeAsyncIterator()
      do {
        while let element = try await iter.next() {
          cont.yield(element)
        }
      } catch {
        cont.yield(with: .failure(error))
      }
    }
    cont.onTermination = { _ in
      it.cancel()
    }
  }
}

extension AsyncStream {
  /// Type erasure of non-failing async sequence.
  @available(iOS 18, *)
  public init<S: AsyncSequence>(isolation: isolated (any Actor)? = #isolation, _ source: S)
  where S.Element == Element, S.Failure == Never {
    let (stream, cont) = AsyncStream.makeStream()

    self = stream
    let it = Task {
      _ = isolation
      var iter = source.makeAsyncIterator()
      do {
        while let element = try await iter.next() {
          cont.yield(element)
        }
      } catch is Never {}
    }
    cont.onTermination = { _ in
      it.cancel()
    }
  }
  /// Type erasure of imperative bridging async sequence types.
  ///
  /// This method erases any upstream async sequence type which directly uses an `AsyncStream.AsyncIterator`
  /// to `AsyncStream`. It is a thin wrapper which does not modify the upstream sequence's buffering policy.
  public init<S: AsyncSequence>(
    isolation: isolated (any Actor)? = #isolation,
    source: S,
    map transform: @escaping (S.Element) -> Element
  ) where S.AsyncIterator == AsyncStream<S.Element>.AsyncIterator {
    let (stream, cont) = AsyncStream.makeStream()

    self = stream
    let it = Task {
      _ = isolation
      var iter = source.makeAsyncIterator()
      while let element = await iter.next() {
        let mappedElement = transform(element)
        cont.yield(mappedElement)
      }
    }
    cont.onTermination = { _ in
      it.cancel()
    }
  }
  /// Type erasure of imperative bridging async sequence types.
  ///
  /// This method erases any upstream async sequence type which directly uses an `AsyncStream.AsyncIterator`
  /// to `AsyncStream`. It is a thin wrapper which does not modify the upstream sequence's buffering policy.
  public init<S: AsyncSequence>(
    isolation: isolated (any Actor)? = #isolation,
    source: S,
    compactMap transform: @escaping (S.Element) -> Element?
  ) where S.AsyncIterator == AsyncStream<S.Element>.AsyncIterator {
    let (stream, cont) = AsyncStream.makeStream()

    self = stream
    let it = Task {
      _ = isolation
      var iter = source.makeAsyncIterator()
      while let element = await iter.next() {
        if let mappedElement = transform(element) {
          cont.yield(mappedElement)
        }
      }
    }
    cont.onTermination = { _ in
      it.cancel()
    }
  }
}

extension AsyncStream {
  /// Type erasure of imperative bridging async sequence types.
  ///
  /// This method erases any upstream async sequence type which directly uses an `AsyncStream.AsyncIterator`
  /// to `AsyncStream`. It is a thin wrapper which does not modify the upstream sequence's buffering policy.
  public init<S: AsyncSequence>(
    isolation: isolated (any Actor)? = #isolation,
    source: S,
    map transform: @escaping (S.Element) -> Element
  ) where S.AsyncIterator == NotificationCenter.Notifications.AsyncIterator {

    let (stream, cont) = AsyncStream.makeStream()

    self = stream
    let it = Task {
      _ = isolation
      let iter = source.makeAsyncIterator()
      while let element = await iter.next() {
        let mappedElement = transform(element)
        cont.yield(mappedElement)
      }
    }
    cont.onTermination = { _ in
      it.cancel()
    }
  }

  /// Type erasure of imperative bridging async sequence types.
  ///
  /// This method erases any upstream async sequence type which directly uses an `AsyncStream.AsyncIterator`
  /// to `AsyncStream`. It is a thin wrapper which does not modify the upstream sequence's buffering policy.
  public init<S: AsyncSequence>(
    isolation: isolated (any Actor)? = #isolation,
    source: S,
    compactMap transform: @escaping (S.Element) -> Element?
  ) where S.AsyncIterator == NotificationCenter.Notifications.AsyncIterator {
    let (stream, cont) = AsyncStream.makeStream()

    self = stream
    let it = Task {
      _ = isolation
      let iter = source.makeAsyncIterator()
      while let element = await iter.next() {
        if let mappedElement = transform(element) {
          cont.yield(mappedElement)
        }
      }
    }
    cont.onTermination = { _ in
      it.cancel()
    }
  }
}

public typealias AsyncInitiallyNilSequence<Source: AsyncSequence> = AsyncChain2Sequence<
  AsyncSyncSequence<[Source.Element?]>,
  AsyncMapSequence<Source, Source.Element?>
>
public typealias AsyncInitiallyNilOptionalSequence<Source: AsyncSequence> = AsyncChain2Sequence<
  AsyncSyncSequence<[Source.Element]>,
  AsyncMapSequence<Source, Source.Element>
>
public typealias InitiallyNilFiringCombineLatest2<Source1: AsyncSequence, Source2: AsyncSequence> =
  AsyncCombineLatest2Sequence<
    AsyncInitiallyNilSequence<Source1>,
    AsyncInitiallyNilSequence<Source2>
  >

extension AsyncSequence {

  public func optionalized<Wrapped>(_: Wrapped.Type = Wrapped.self) -> Self
  where Self.Element == Wrapped? {
    self
  }

  @_disfavoredOverload
  public func optionalized() -> AsyncMapSequence<Self, Self.Element?> where Self.Element: Sendable {
    map(Optional.init)
  }

  /// Make the elements of the sequence optional and add a `Optional<Element>.none` prefix.
  ///
  @_disfavoredOverload
  public func withNilPrefix() -> AsyncChain2Sequence<
    AsyncSyncSequence<[Self.Element?]>,
    AsyncMapSequence<
      Self,
      Self.Element?
    >
  > where Self.Element: Sendable {
    chain([Self.Element?(nil)].async, map(Optional.init))
  }

  /// Add an `Optional<Element>.none` prefix element to a sequence which already has an optional element type
  public func withNilPrefix<WrappedElement>()
    -> AsyncChain2Sequence<
      AsyncSyncSequence<[Self.Element]>,
      AsyncMapSequence<
        Self,
        Self.Element
      >
    > where Self.Element == WrappedElement?
  {
    chain([.none].async, map(\.self))
  }

}
