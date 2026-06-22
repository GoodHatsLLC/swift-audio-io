// © GoodHatsLLC

import Dispatch
import Testing

// Pins this package's async-executor contract under the
// `NonisolatedNonsendingByDefault` upcoming feature (SE-0461), enabled in
// Package.swift.
//
// Under that feature a *plain* `nonisolated async` function runs on the
// CALLER's actor — so when awaited from a `@MainActor` context it executes on
// the MAIN ACTOR, NOT the global executor. To actually move blocking work off
// the main actor a function MUST be annotated `@concurrent`.
//
// This is a silent footgun: a plain `nonisolated async` "off-main" helper still
// compiles, still returns correct results, and still passes functional tests —
// it just runs on the caller's actor. These tests assert MAIN-ACTOR isolation
// (via `MainActor.assertIsolated()`), not the raw OS thread, and fail loudly if
// the package's executor contract ever changes — documenting why off-main
// helpers (file I/O, file/session teardown) are `@concurrent`.

private struct ExecutorProbe {
  /// Plain `nonisolated async`: inherits the caller's actor under SE-0461, so
  /// `MainActor.assertIsolated()` must pass (not trap) when awaited from
  /// `@MainActor`.
  nonisolated func assertInheritsMainActor() async {
    MainActor.assertIsolated(
      "A plain nonisolated async awaited from @MainActor must run on the main actor under NonisolatedNonsendingByDefault.",
    )
  }

  /// `@concurrent`: always hops to the global concurrent executor, so it is NOT
  /// isolated to the main actor. `dispatchPrecondition(.notOnQueue(.main))`
  /// passes off the main actor and traps on it.
  @concurrent
  nonisolated func assertRunsOffMainActor() async {
    dispatchPrecondition(condition: .notOnQueue(.main))
  }
}

@MainActor
@Test("plain nonisolated async inherits the main actor (SE-0461)")
func plainNonisolatedAsyncInheritsMainActor() async {
  // Passes by NOT trapping: the probe runs on the main actor, so assertIsolated
  // succeeds. If the executor contract regressed (plain → global executor) this
  // would trap.
  await ExecutorProbe().assertInheritsMainActor()
}

@MainActor
@Test("@concurrent forces work off the main actor")
func concurrentForcesOffMainActor() async {
  // Passes by NOT trapping: the @concurrent probe runs off the main actor.
  await ExecutorProbe().assertRunsOffMainActor()
}
