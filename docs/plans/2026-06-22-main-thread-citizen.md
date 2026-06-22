# Main-thread citizen: recording-start hang fix + off-main plan

Date: 2026-06-22
Status: **in progress** — recording-START fixed and shipped (`aa43c1b`); remaining areas planned below, gated on a shared serialization primitive.

## Context

A report that *"beginning recording can cause main thread hangs"* prompted an audit of whether the
framework is a good `@MainActor` / main-thread citizen: i.e. whether public API that runs on the main
actor (or hops to it via `MainActor.run`) performs blocking work on the main thread.

It does, in many places. The blocking primitives are:

- **`AVAudioSession` IPC** — `setActive`, `setCategory`, `setPreferred*` (each is mediaserverd IPC;
  `setActive(true/false)` routinely blocks 10–100 ms+, worse during route negotiation).
- **Synchronous engine-control-queue dispatch** — `runOnEngineControlQueue` /
  `runOnEngineControlQueueResult` are `engineControlQueue.sync` (blocking). The async siblings
  `withEngineControlQueue` / `withEngineControlQueueResult` are not (`AIOEngine.swift:501-533`).
- **`AVAudioEngine`** — `start()`, `prepare()`, `stop()`, `reset()`, `installTap`/`removeTap`,
  `inputNode.inputFormat(forBus:)`.
- **File I/O** — `AVAudioFile(forWriting:/forReading:)`, `ExtAudioFile` create, `close()`,
  `FileManager` directory creation.
- **Allocation** — `SPSCRingBuffer` sized `sampleRate * maxBufferSeconds * channels`.

## Method

Multi-agent audit + adversarial verification (mirrors `2026-06-09-core-audio-system-audio-capture-review.md`).
Five area readers (recording-start, recording-stop, playback, session/route/interruption, device
enumeration) mapped every blocking op reachable on the main thread; each candidate was then handed to an
independent verifier instructed to confirm it executes **on the main thread**, reachable from a public API,
and to propose a minimal fix that preserves the realtime/concurrency model. Implementation changes were
likewise put through adversarial review lenses (realtime/ordering, isolation/data-race, behavior
preservation) before landing.

## Outcome of the audit

- **67** candidate findings → **55 confirmed** main-thread blockers.
- Severity: **10 critical, 25 high, 13 medium, 7 low**.
- The 55 collapse to a handful of root causes, cross-cutting the five areas through shared helpers
  (`reinstallTap`, `configureAudioSession`, `deactivateAudioSessionIfNeeded`,
  `configureAudioSessionForPlayback`). This is why the remaining work below is sequenced by **mechanism**,
  not by area — each shared helper is fixed once.

| Severity | Root cause | Reached by |
|---|---|---|
| critical | `startRecording` wrapped the entire bring-up in one `MainActor.run` | **the reported bug** |
| critical | `configureAudioSession` — 6× `AVAudioSession` IPC on main | start, stop, route |
| critical | `warm` + `reinstallTap` — `engineControlQueue.sync` graph mutation on main | start, route |
| high | `tearDownEngineGraphForHardStop` sync; `gracefulStop`→`deactivateAudioSessionIfNeeded` (`setActive(false)`) | stop |
| high | playback `play`/`playSegment` — `configureAudioSessionForPlayback` + `AVAudioFile(forReading:)` | playback |
| high | session/route/interruption handlers — `setCategory`/`setActive`/engine ops on main | route, MS-reset |
| medium | `AudioEnvironment` getters (`availableInputs`/`currentRoute`/…) — IPC property reads on `@MainActor` | enumeration |

---

## Work done — recording START (shipped: `aa43c1b`)

The reported bug. `RecordingRuntime.startRecording(configuration:)` wrapped the **entire** bring-up in a
single `MainActor.run`: `warm()` (session config + sync engine-graph mutation + buffer alloc + file open)
**and** `engine.start()` all ran on the main thread — an estimated **~50–300 ms** stall on a cold start,
**repeating per reconciliation retry**.

**Fix shape:** the bring-up no longer runs on the main actor.

- Extracted `warm` into a `nonisolated func performWarm(configuration:inputs:)`; made the dependency chain
  `nonisolated` (`configureAudioSession`, `reinstallTap`, `makeRecordingWriter`, `resolveOutputURL`,
  `applyFileProtectionIfNeeded`, `validateEncoderCompatibility`, `makeTapConversionArtifacts`). The
  `Mutex`-backed `state` makes the off-main work data-race-safe; the genuinely `@MainActor` values
  (`recordingSessionConfiguration`, `writerBackend`, pre-resolved DEBUG tap-override) are threaded through a
  `Sendable WarmInputs`.
- `startRecording` is now: **PREP hop** (main — playback teardown, capture `WarmInputs`, activate the
  `@MainActor` session delegate) → **off-main** `performWarm` + engine start via the async
  `withEngineControlQueueResult` → **PUBLISH hop** (main — events, writer/receiver loops,
  `isRecording = true`).
- Public `warm()` API and all signatures preserved; RT/tap code, `engineControlQueue` ordering, and event
  types unchanged. Cheap validation now runs before session activation, so an invalid config no longer
  leaves the session active.

**The window guard (the subtle part).** Moving off-main *necessarily* yields the main actor mid-bring-up,
so independent `@MainActor` handlers can run while `wantsRecording == true` but `isRecording == false`.
Without a guard, an interruption/stop/media-services event would `gracefulStop` a half-built engine
(orphaned running engine, lost stop). Guarded with two main-actor flags on `AIOEngine`:

- `isStartingRecording` — open across the off-main window. While set, teardown handlers
  (`handleUnrecoverableInterruption`, `handleInterruption(.began)`, `handleRouteChange`,
  `handleMediaServicesLost`) and the stop paths **defer** instead of tearing down inline.
- `startAbortRequested` — set by a deferring handler/stop. The PUBLISH-hop reconcile honors an abort
  **only** on this flag (deliberately **not** `wantsRecording`, which is legitimately `false` on the direct
  `startRecording()` API), `gracefulStop`s the just-started engine, and emits `recordingFailed` only for
  interruption-origin aborts. The window opens only **after** the fallible delegate activation, so it can
  never get stuck.

**Verification:** macOS `swift build` + `--build-tests` green; iOS build green; **full 235-test iOS suite
passes** (incl. interruption-during-recording, route-change, start/stop). Two adversarial review rounds
caught 12 defects (including a critical "direct start self-destructs" bug and the bring-up window); all
fixed before landing.

---

## Key architectural finding (gates all remaining work)

A first attempt at the engine-control-queue area (route-change `reinstallTap`, tap-interval, `hardStop`)
was **reverted** because adversarial review found **4 high-severity races**. The cause is general, not
incidental:

> The `@MainActor` engine handlers — `handleRouteChange`, `handleInterruption`,
> `gracefulStop`/`stopRecording`, and the tap-interval `reconfigureTapForIntervalChange` — are
> **independent concurrent tasks** (route/interruption handlers are task-group children in
> `AudioEnvironmentLifecycleRuntime.run`, `~:108-144`). The current blocking-sync engine code
> (`runOnEngineControlQueue`, sync `reinstallTap`) is **accidentally race-free because it never
> suspends**: from `guard isRecording` to the graph mutation there is no `await`, so no other main-actor
> work can interleave.

The moment any of these is converted to `await` (the whole point of going off-main), an interleaving
window opens. Concrete hazard: `gracefulStop` enqueues its teardown on `engineControlQueue` while
`isRecording` is **still true** (it sets `isRecording = false` *late*, after the writer-drain `await`); a
route-change/tap-interval reinstall then passes its main-actor `guard isRecording`, suspends at `await`,
and enqueues a tap **install** that runs on the serial queue **after** the teardown — reinstalling a live
tap onto a torn-down/stopped graph, then `applyTapInstallResult` resurrects converter/`installedTapBus`
state that `cleanUp` just cleared. Net: leaked tap, resurrected state, spurious `routeChangeContinuing`
events after a completed stop. With `stopEngine: true` (route change) the reinstall also **restarts** the
engine after stop.

**A main-actor pre-check cannot close this** (the stop hasn't flipped `isRecording` yet). The fix must live
**on the engine-control queue** — the only place serialized against teardown.

### Required primitive: engine teardown serialization

Add a teardown sentinel that graph mutations honor **on the serial queue**:

1. `gracefulStop()` and `hardStop()` set a synchronous flag (e.g. `engineTearingDown`, atomic or in
   `Mutex` `state`) **before** enqueuing their teardown — i.e. before the drain `await`, not after.
2. The on-queue reinstall body (`reinstallTapOnEngineControlQueue` in `AIOEngine+TapSetup.swift`) checks the
   flag at the top and **bails before mutating the graph** if a teardown has superseded it.
3. `warm`/`performWarm` clears the flag when a new bring-up legitimately starts.
4. Each `await reinstallTapAsync` caller additionally re-checks `guard isRecording` **after** the await,
   before `applyTapInstallResult`/event emission (closes the post-await tail).

A generation counter (teardown increments; reinstall captures-then-compares on-queue) is an equivalent,
slightly more general formulation. Whichever is chosen, **this primitive is a prerequisite for Chunk 1 and
reused by Chunk 2** — implement it first.

---

## Remaining work

Sequenced by mechanism (shared helpers fixed once). Each chunk: **fix → adversarial review (ordering /
isolation / behavior) → authoritative iOS build + full test suite → commit**. The iOS build is mandatory —
most session code is `#if os(iOS)` and **not compiled by macOS `swift build`**, so isolation/compile errors
there are invisible until an `xcodebuild ... -destination 'platform=iOS Simulator'` run.

### Chunk 0 — engine teardown serialization primitive (prerequisite)
Implement the `engineTearingDown` sentinel / generation guard described above. No behavior change on its
own; unblocks Chunk 1 and de-risks Chunk 2. Add a regression test: enqueue a reinstall, request a stop, and
assert the tap is **not** left installed after teardown (drive deterministically via the existing
`testReinstallTapOverride` / `testEngineTeardownOverride` seams).

### Chunk 1 — engine-control-queue off-main
- `reinstallTap` (`AIOEngine+TapSetup.swift`): factor the on-queue install body into a shared helper; keep
  the existing **sync** wrapper (used by off-main `performWarm`; the public `warm()` must stay sync) and add
  `reinstallTapAsync(...) async` over the async `withEngineControlQueueResult`. Honor `overrideResult` on
  both.
- `@MainActor` callers `await` the async variant **and** re-check liveness post-await + honor Chunk 0's
  on-queue guard: `handleRouteChange` (`AIOEngine+Interruptions.swift`, `+macOS.swift`),
  `reconfigureTapForIntervalChange` (`RecordingEngineRuntime.swift`). If `reconfigureTapForIntervalChange`
  becomes async, keep `updateRecordingTapInterval`'s public signature; if it schedules a
  `MainActorOwnedWork`, **store the handle** in an owner property (cancelled on stop/teardown) rather than
  discarding it.
- `hardStop` **stays sync** (called from the start PREP sync `MainActor.run` and failure path). Make its
  `tearDownEngineGraphForHardStop` dispatch via `engineControlQueue.async` (fire-and-forget), mirroring
  `tearDownEngineGraphForGracefulStop` which already does this. FIFO on the serial queue preserves ordering.
- `rotateRecordingFile` (`RecordingRuntime.swift`): hoist the file prep (`resolveOutputURL` +
  `makeRecordingWriter`, both now `nonisolated`) off-main, then re-enter main only for the state swap.

### Chunk 2 — `AVAudioSession` IPC off-main (most entangled)
The blocking IPC routes through the `@MainActor AudioSessionDelegate` protocol, so the work goes deeper than
the call sites: `AudioSessionController.setAudioSessionActive` (the delegate impl) must run
`env.session.setActive(...)` off-main (`env.session` is an immutable `let`). Reuse the established off-main
pattern `AudioEnvironmentManager.executeInputConfiguration` (`AudioEnvironmentManager.swift:~180-191`,
"computed on MainActor then executed off MainActor"). Touches: `deactivateAudioSessionIfNeeded`,
`configureAudioSessionForPlayback`, `applyAudioSessionConfiguration`, `AudioSessionBootstrap`
(`configureAudioSessionCategory` is already `nonisolated static`), `AudioEnvironmentLifecycleRuntime`,
`AudioEnvironment.request` (`setPreferredInput`). **Re-touches the start PREP `activateAudioSessionDelegate`**
— if the delegate call becomes async it must be awaited before the bring-up window opens, so revisit
`startRecording` PREP. Make `deactivateAudioSessionIfNeeded` / the controller `async` and `await` from
`gracefulStop` and `stopPlayback`.

### Chunk 3 — file I/O off-main
- Playback `play` / `playSegment` (`PlaybackRuntime.swift`): open `AVAudioFile(forReading:)` off-main before
  any main-actor work; activate the session via Chunk 2's async path.
- `stopPlayback`: move `AVAudioFile.close()` off-main (fold into the existing `withEngineControlQueue` hop).

### Chunk 4 — device/input enumeration (cache + background refresh)
The `@MainActor` getters `AudioEnvironment.availableInputs` / `.input` (`currentRoute`) / `.source`
(`inputDataSource`) and `AudioEnvironmentManager.inputHasStereoSource` do synchronous mediaserverd IPC.
**Decision (made):** keep the synchronous getter API, but serve **cached** values refreshed off-main on
`AVAudioSession` route-change / availability notifications (the manager already observes these). Getters
become non-blocking and instant; no API break.

---

## Constraints (all chunks)

- Never block the main thread in the changed paths.
- Preserve `engineControlQueue` **FIFO ordering**, all event **types and order**, error types, and **public
  API signatures** (`warm`, `updateRecordingTapInterval`, the enumeration getters).
- Do not touch RT/tap-callback code or buffer math.
- Preserve the `#if DEBUG` seams (`testReinstallTapOverride`, `testEngineTeardownOverride`).
- Every off-main conversion that introduces an `await` on an engine/session lifecycle path **must** be
  guarded against interleaving (Chunk 0 primitive + post-await re-checks), or it reopens the race class
  above.

## References

- Recording-start fix: commit `aa43c1b`.
- Audit raw result (55 confirmed findings with per-item fix sketches): session artifact
  `tasks/w5lyyb0cm.output` (not in-repo; regenerate via the audit method above if needed).
- Window-guard flags: `AIOEngine.isStartingRecording`, `AIOEngine.startAbortRequested`
  (`AIOEngineCore/AIOEngine.swift`).
