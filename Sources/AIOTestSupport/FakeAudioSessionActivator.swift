// © GoodHatsLLC

#if os(iOS)
  package import AIOAudioSession
  package import AVFAudio
  import Foundation
  package import Tools

  /// A scriptable stand-in for the platform activation path.
  ///
  /// Records every request in order so a test can assert *how many* platform
  /// transitions happened and in what sequence — the thing the real
  /// `AVAudioSession` cannot be asked. Delays make the in-flight window wide
  /// enough to drive supersession deterministically without sleeping on wall
  /// clock guesses.
  package final class FakeAudioSessionActivator: AudioSessionActivating {
    /// One recorded activation request.
    package struct Call: Sendable, Hashable {
      package let active: Bool
      /// Zero-based order in which the request reached the activator.
      package let index: Int
    }

    /// Per-call behaviour, keyed by zero-based call index.
    ///
    /// - Parameters:
    ///   - failureForCall: returns an error to throw instead of succeeding.
    ///   - gateForCall: an optional barrier awaited *before* the call is
    ///     recorded as complete, so a test can hold one activation open and
    ///     issue another.
    package init(
      failureForCall: @escaping @Sendable (Int) -> AudioSessionActivationError? = { _ in nil },
      gateForCall: @escaping @Sendable (Int) -> AsyncSignal<Void>? = { _ in nil },
    ) {
      self.failureForCall = failureForCall
      self.gateForCall = gateForCall
    }

    private let failureForCall: @Sendable (Int) -> AudioSessionActivationError?
    private let gateForCall: @Sendable (Int) -> AsyncSignal<Void>?
    private let recorded = Synchronized<[Call]>([])
    private let started = Synchronized<Int>(0)

    /// Every completed request, in completion order.
    package var calls: [Call] {
      recorded.withLock { $0 }
    }

    /// The `active` argument of every completed request, in completion order.
    package var appliedStates: [Bool] {
      calls.map(\.active)
    }

    /// How many requests reached the activator, including ones still in flight.
    package var startedCount: Int {
      started.withLock { $0 }
    }

    package func setActive(
      _ active: Bool,
      session _: AVAudioSession,
    ) async throws(AudioSessionActivationError) {
      let index = started.withLock { count -> Int in
        let index = count
        count += 1
        return index
      }

      if let gate = gateForCall(index) {
        for await _ in gate.events() { break }
      }

      if let failure = failureForCall(index) {
        throw failure
      }

      recorded.withLock { $0.append(Call(active: active, index: index)) }
    }
  }
#endif
