# Design Document: AIO Engine iOS Audio Threading Conformance

**Author**: Claude
**Date**: 2026-02-16
**Status**: Draft
**Scope**: `Packages/AIO/` — `AIOEngine`, `Tools`

---

## 1. Executive Summary

This document evaluates the AIO engine against the iOS audio threading best practices
described in the reference document *"iOS audio API threading: the complete contract"* and
proposes changes to close the gaps. The reference distills Apple documentation, WWDC
sessions, and open-source precedents (WebRTC, The Amazing Audio Engine, AudioKit) into a
concrete threading architecture: a serial configuration queue, lock-free communication
primitives, C/C++ render code, and workgroup membership for auxiliary real-time threads.

**Key finding**: AIO already implements most of the recommended architecture — serial
configuration queue, SPSC ring buffers, atomic state flags, and separated thread domains.
The remaining gaps are real but bounded: a mutex acquired on the tap thread, missing
runtime diagnostics, an allocation in the writer loop hot path, and absent Audio Workgroup
support. None of these are causing known production issues today, but addressing them
would harden AIO against edge-case glitches and align it with the documented best
practices of every mature iOS audio framework.

---

## 2. Current Architecture Assessment

### 2.1 What AIO Already Does Well

AIO's threading model is already substantially aligned with the recommendations. The
following patterns are in place and should be preserved:

| Recommendation | AIO Implementation | Location |
|---|---|---|
| Serial configuration queue for AVAudioEngine | `engineControlQueue` (serial, `.default` QoS) | `AIOEngine.swift:295` |
| All graph mutations through serial queue | `runOnEngineControlQueue`, `withEngineControlQueue` | `AIOEngine.swift:439–471` |
| Lock-free SPSC ring buffers | `SPSCRingBuffer<T>` with `ManagedAtomic` indices | `Tools/Async/SPSCRingBuffer.swift` |
| Atomic state flags for cross-thread signals | `ManagedAtomic<Bool/Int/Int64>` for writer control, tap errors, sample time | `AIOEngine.swift:299–305`, `AIOEngine+Types.swift` |
| Dedicated writer queue (off-main file I/O) | `writerQueue` (serial, `.userInitiated` QoS) | `AIOEngine.swift:296` |
| Dedicated receiver queue (visualization) | `receiverQueue` (serial, `.userInitiated` QoS) | `AIOEngine.swift:297` |
| Pre-allocated converter and buffers before tap starts | `TapConversionArtifacts` created in `reinstallTap()` | `AIOEngine+TapSetup.swift:21–47` |
| Configure-early, activate-late session pattern | Category set at app launch; `setActive` only on record/play intent | `AudioEnvironmentManager.swift:68–79`, `AIOEngine+AudioSession.swift:12` |
| Route change tap reinstallation | `handleRouteChange` → `reinstallTap(stopEngine: true)` | `AIOEngine+Interruptions.swift:19–73` |
| Interruption and media services reset handling | Full lifecycle with graceful stop and reconciliation | `AIOEngine+Interruptions.swift:102–168` |
| Error reporting from tap via atomics (no allocation) | `tapErrorCode: ManagedAtomic<Int>`, polled by writer/receiver | `AIOEngine.swift:304`, `AIOEngine+Recording.swift:781–949` |
| Typed-throws error model | `AIOError` with `isTransient` for reconciliation | `AIOEngine.swift:78–190` |
| AVAudioSession configuration on MainActor | All `configureAudioSession` methods are `@MainActor` | `AIOEngine+AudioSession.swift:12,72,97` |
| Writer loop uses synchronous blocking (no async/await) | `writerLoopSync` with `Thread.sleep` backoff | `AIOEngine+Recording.swift:990–1098` |

### 2.2 Thread Domain Map (Current)

AIO recognizes four thread domains, matching the reference's three-domain model plus a
fourth for visualization:

```
┌────────────────────────────────────────────────────────────┐
│                    MainActor (UI/State)                     │
│  isRecording, playback, reconciliation, callbacks,          │
│  AVAudioSession configuration, lifecycle coordination       │
└──────────────────┬──────────────────────┬──────────────────┘
                   │                      │
          sync dispatch              async dispatch
                   │                      │
┌──────────────────▼──────────────────┐   │
│     engineControlQueue (serial)     │   │
│  attach, connect, start, stop,      │   │
│  prepare, reset, installTap         │   │
└──────────────────┬──────────────────┘   │
                   │                      │
            [AVAudioEngine               │
             manages internally]          │
                   │                      │
┌──────────────────▼──────────────────┐   │
│       Tap Thread (RT-adjacent)      │   │
│  processAudio() — convert, enqueue  │   │
│  to SPSC ring buffers               │   │
└────┬──────────────────────┬─────────┘   │
     │ SPSC                 │ SPSC        │
     ▼                      ▼             │
┌────────────┐    ┌──────────────────┐    │
│ writerQueue│    │  receiverQueue   │◄───┘
│ (file I/O) │    │ (visualization)  │
└────────────┘    └──────────────────┘
```

### 2.3 Tap Thread Characterization

A critical nuance from the reference document: **AVAudioEngine tap blocks do NOT run on
the real-time audio render thread.** WWDC 2019 (Session 510) clarified that taps run on an
internal `RealtimeMessenger.mServiceQueue`, while only `AVAudioSourceNode` and
`AVAudioSinkNode` render blocks run under real-time constraints.

This means AIO's tap callback (`processAudio`) is in a **semi-real-time context** — not
the hard-deadline render thread, but still latency-sensitive. The practical consequence:
mutex acquisition and Swift ARC operations are *less dangerous* in a tap than in a source
node render block, but can still cause audible glitches if they contend with a
lower-priority thread.

AIO does not use `AVAudioSourceNode` or `AVAudioSinkNode`, so the strictest real-time
constraints do not currently apply to any AIO code path.

---

## 3. Gap Analysis

### 3.1 CRITICAL: Mutex Acquisition in Tap Callback

**Current behavior**: `processAudio()` calls `state.withLock { ... }` to read the
converter, buffers, format, and other internal state. This acquires an `os_unfair_lock`
(via `Synchronized<InternalState>` → `Mut<Value>` → `Mutex` or
`OSAllocatedUnfairLock`).

**Risk**: Although the tap does not run on the hard-real-time render thread, acquiring a
mutex on the tap's semi-RT thread creates priority inversion risk. If the MainActor
thread holds the same lock (e.g., during `cleanUp()`, `warm()`, or
`applyTapInstallResult()`), the tap thread blocks. A medium-priority thread could then
preempt the MainActor thread, causing the tap to miss its deadline.

**`os_unfair_lock` specifics**: Unlike `pthread_mutex`, `os_unfair_lock` does provide
priority donation on Apple platforms, which mitigates (but does not eliminate) priority
inversion. The lock holder's priority is temporarily boosted to match the waiter's. This
makes the current implementation safer than a naive `pthread_mutex`, but the lock is still
a blocking call that could cause jitter.

**Reference recommendation**: Lock-free reads on the render/tap path. TAAE uses
`AEManagedValue` for atomic reference swaps; WebRTC uses atomic booleans and detached
thread checkers.

**Severity**: Medium. The `os_unfair_lock` with priority donation is a reasonable choice
for a tap block (not hard RT). However, the lock protects a struct with ~10 optional
fields, meaning the critical section is wider than necessary. Contention during route
changes or recording start/stop is plausible.

### 3.2 MODERATE: AVAudioPCMBuffer Allocation in Writer Loop

**Current behavior**: `flushChunk()` allocates a new `AVAudioPCMBuffer` on every call:

```swift
guard let pcmBuffer = AVAudioPCMBuffer(
    pcmFormat: audioFormat,
    frameCapacity: AVAudioFrameCount(bufferSize)
) else { ... }
```

**Risk**: This is on the `writerQueue`, not the tap thread, so it doesn't violate
real-time constraints. However, it creates unnecessary heap allocation pressure — one
`AVAudioPCMBuffer` allocation per 1024-frame write chunk, potentially hundreds per second
at high sample rates. This can cause GC pressure and cache thrashing on memory-constrained
devices.

**Reference recommendation**: Pre-allocate write buffers.

**Severity**: Low-to-moderate. Not a correctness issue, but a performance optimization.

### 3.3 MODERATE: No Runtime Real-Time Safety Assertions

**Current behavior**: AIO has no mechanism to detect real-time violations at runtime. If
a future change inadvertently introduces a lock acquisition, heap allocation, or ObjC
message send on the tap thread, it would go undetected until an audible glitch occurs.

**Reference recommendation**: TAAE ships `RealtimeWatchdog`, which monitors for locks,
allocations, ObjC messaging, and I/O on the audio thread. It also provides
`AECurrentThreadIsAudioThread()` for runtime assertions.

**Severity**: Medium for maintainability. Not a current issue, but a regression
prevention gap.

### 3.4 LOW: No Audio Workgroup Support

**Current behavior**: AIO does not use `os_workgroup_join` or `AURenderContextObserver`.

**Risk**: Audio Workgroups (iOS 14+) allow the kernel's performance controller to
schedule real-time threads appropriately (preventing them from landing on efficiency
cores). However, AIO does not create custom real-time threads — it uses AVAudioEngine
which manages its own workgroup internally, plus standard `DispatchQueue`s for
writer/receiver.

**Reference recommendation**: Any auxiliary real-time threads must join the audio
workgroup. Custom threads doing time-sensitive audio work at low buffer sizes (< 512
samples) can fail without workgroup membership.

**Severity**: Low for current architecture. AIO's writer and receiver queues are not
real-time threads and do not need workgroup membership. This would only become relevant if
AIO dropped to Core Audio render callbacks or `AVAudioSourceNode`/`AVAudioSinkNode`.

### 3.5 LOW: Notification Thread Dispatch Not Explicitly Verified

**Current behavior**: `AudioEnvironment.Notifications` wraps
`NotificationCenter.notifications(named:)` into `AsyncStream` sequences. The reference
document warns that AVAudioSession notifications arrive on an internal "AVAudioSession
Notify Thread", not the main thread.

**Current mitigation**: `AudioEnvironmentManager` is `@MainActor`, and its `run()` method
iterates these streams inside `withThrowingTaskGroup`. The `for await` consumption of
these streams inherits the caller's isolation context (MainActor), so notification
processing is already dispatched to MainActor.

**Risk**: Minimal. The `compactMap` closures in `AudioEnvironment.Notifications` execute
on the notification's originating thread (the AVAudioSession Notify Thread), but they
only parse `userInfo` dictionaries — no mutable state access. The actual handlers run on
MainActor.

**Severity**: Low. The current design is correct. A defensive improvement would be to add
a comment documenting this threading contract.

### 3.6 LOW: `configureAudioSessionCategory` Is `nonisolated static`

**Current behavior**: `AudioEnvironmentManager.configureAudioSessionCategory(_:configuration:)`
is marked `nonisolated static` and can be called from any thread.

**Reference recommendation**: Apple DTS recommends calling AVAudioSession configuration
methods from the main thread.

**Current mitigation**: The two call sites are:
1. `prepareAudioSessionCategoryForAppLaunch()` — `@MainActor` ✓
2. `run()` inside a `group.addTask { ... }` — runs on a cooperative thread pool thread,
   not MainActor ✗

**Severity**: Low. Setting the session category before activation is a one-time
operation at launch, and Apple's recommendation is informal (DTS response, not
documentation). The category call is unlikely to hang on a background thread, but
aligning with the recommendation is straightforward.

### 3.7 INFORMATIONAL: Swift on Tap Thread

**Current behavior**: `processAudio()` is pure Swift. It accesses `AVAudioConverter`,
operates on `UnsafeBufferPointer`, calls `SPSCRingBuffer.write()`, and increments
atomics.

**Reference recommendation**: "Swift cannot be used safely on the real-time audio thread"
due to ARC, copy-on-write, exclusivity checks, and error allocation.

**Applicability**: This recommendation applies to **hard-real-time render callbacks**
(`AVAudioSourceNode`, `AVAudioSinkNode`, Core Audio render callbacks). As established in
§2.3, AIO's tap callback does not run on the render thread. The Swift operations in
`processAudio()` are acceptable in a tap block context.

**However**: `AVAudioConverter.convert(to:error:inputDataSource:)` is an Objective-C API
called from Swift. The method itself may perform internal allocations. This is an
AVFoundation-imposed constraint — the tap block is designed to use the converter.

**Severity**: Informational. No action required for tap blocks. Would need to be revisited
if AIO ever adopts `AVAudioSourceNode` or drops to Core Audio render callbacks.

### 3.8 INFORMATIONAL: `nonisolated(unsafe)` on AVAudioEngine/AVAudioPlayerNode

**Current behavior**: `engine` and `player` are marked `nonisolated(unsafe)`:

```swift
nonisolated(unsafe) let engine = AVAudioEngine()
nonisolated(unsafe) let player = AVAudioPlayerNode()
```

**Justification**: All mutations are serialized through `engineControlQueue`. The
`nonisolated(unsafe)` annotation is necessary because Swift concurrency cannot verify
that all accesses occur on a specific `DispatchQueue`. This is the standard pattern for
wrapping AVFoundation objects in Swift 6 strict concurrency.

**Risk**: If a future change accesses `engine` or `player` outside the
`engineControlQueue` without going through the existing helpers, the compiler will not
catch the violation.

**Severity**: Informational. The existing pattern is correct. Adding runtime assertions
(see §3.3) would help catch violations.

---

## 4. Proposed Changes

### Priority Levels

- **P1**: Should be addressed — measurable risk reduction or alignment with best practice
- **P2**: Nice to have — performance improvement or maintainability gain
- **P3**: Future consideration — relevant only if architecture evolves

---

### 4.1 [P1] Replace Mutex With Snapshot for Tap Callback State

**Goal**: Eliminate the `state.withLock()` call from `processAudio()` so the tap callback
never acquires a blocking lock.

**Approach**: Introduce a `TapSnapshot` struct that contains all fields `processAudio()`
reads from `InternalState`. Store it in an `Atomic<Int>` indexed triple-buffer or
`ManagedAtomic`-guarded slot. The configuration thread writes a new snapshot; the tap
thread reads the latest snapshot without locking.

**Design**:

```
┌──────────────────────────────────┐
│ Configuration (MainActor +       │
│ engineControlQueue)              │
│                                  │
│ 1. Create TapSnapshot            │
│ 2. Write to slot                 │
│ 3. Release-store index           │
└──────────────┬───────────────────┘
               │ atomic index
               ▼
┌──────────────────────────────────┐
│ Tap Thread (processAudio)        │
│                                  │
│ 1. Acquire-load index            │
│ 2. Read snapshot (no lock)       │
│ 3. Use converter, buffers, etc.  │
└──────────────────────────────────┘
```

**`TapSnapshot` struct**:

```swift
struct TapSnapshot {
    let audioBuffers: [SPSCRingBuffer<Float>]?
    let receiverBuffers: [SPSCRingBuffer<Float>]?
    let receiverTiming: SPSCRingBuffer<TimingPacket>?
    let converter: AVAudioConverter?
    let converterInputFormat: AVAudioFormat?
    let converterOutputFormat: AVAudioFormat?
    let convertedBuffer: AVAudioPCMBuffer?
}
```

**Slot mechanism**: Use a pattern inspired by TAAE's `AEManagedValue` — a reference-counted
box with atomic swap:

```swift
final class AtomicBox<T>: @unchecked Sendable {
    // SAFETY: Single-writer (configuration), single-reader (tap). Writer creates
    // new boxes and atomically swaps the pointer. Reader loads the current pointer
    // and reads its immutable contents. Old boxes are released by the writer
    // (not on the tap thread).
    private let _value: ManagedAtomic<UnsafeMutablePointer<Box<T>>?>

    func store(_ value: T) { ... }  // Writer side: allocate new, swap, dealloc old
    func load() -> T? { ... }        // Reader side: atomic load, read contents
}
```

**Alternative (simpler)**: Since `Mut` already wraps `Mutex` which supports
`withLockIfAvailable`, consider a two-phase approach:

1. Try `state.withLockIfAvailable { ... }` first (non-blocking)
2. If lock unavailable, use a stale cached copy (updated on next successful lock acquire)

This is simpler to implement but less pure — there's a brief window where stale state
is used after a route change. The impact is minimal (a few tap callbacks might use the
old converter, which is still valid until the engine is stopped and restarted).

**Recommended approach**: The simpler `withLockIfAvailable` + stale cache approach is
preferable for the initial change. The full atomic-swap slot can be pursued later if
profiling shows contention.

**Files changed**:
- `AIOEngine+Recording.swift` (`processAudio`)
- `AIOEngine+TapSetup.swift` (`applyTapInstallResult`)
- `AIOEngine+Types.swift` (add `TapSnapshot`)
- `AIOEngine.swift` (add snapshot storage)

**Risk**: Low. The tap callback's behavior is unchanged — it reads the same fields. The
only difference is the synchronization mechanism.

**Testing**: Existing `AIOEngineIntegrationTests` cover tap callback behavior. Add a
targeted test that verifies `processAudio` never blocks when the lock is held.

---

### 4.2 [P1] Add DEBUG-Only Tap Thread Safety Assertions

**Goal**: Detect real-time violations at development time before they reach production.

**Approach**: Create a lightweight `RealtimeSafetyChecker` that, in DEBUG builds:

1. Records the tap thread identity on first `processAudio()` invocation
2. Asserts that subsequent calls occur on the same thread (detects unexpected thread
   migration)
3. Optionally hooks `malloc` via `malloc_zone_register` or `__sanitizer` APIs to detect
   allocations on the tap thread (advanced, optional)

**Minimal implementation**:

```swift
#if DEBUG
final class TapThreadChecker: @unchecked Sendable {
    // SAFETY: Only written once (first tap call), then read-only.
    private let _threadID = ManagedAtomic<UInt64>(0)

    func checkThread() {
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        let stored = _threadID.load(ordering: .relaxed)
        if stored == 0 {
            _threadID.store(tid, ordering: .relaxed)
        } else {
            assert(stored == tid,
                   "processAudio called on wrong thread: expected \(stored), got \(tid)")
        }
    }
}
#endif
```

**Allocation detection** (advanced, deferred): Integrate with `MallocStackLogging` or
Apple's `os_signpost` to flag heap allocations during tap callback execution. This
requires C interop and is better suited for a diagnostic tool than inline code.

**Files changed**:
- `AIOEngine.swift` (add checker property)
- `AIOEngine+Recording.swift` (`processAudio` — add `#if DEBUG` check)

**Risk**: Zero production risk (DEBUG-only). Minimal performance impact (one atomic load
per tap callback).

---

### 4.3 [P2] Pre-Allocate Write Buffer in Writer Loop

**Goal**: Eliminate per-chunk `AVAudioPCMBuffer` allocation in `flushChunk()`.

**Approach**: Allocate a single `AVAudioPCMBuffer` when the writer loop starts and reuse
it across all `flushChunk()` calls. Pass it as a parameter to `flushChunk()` instead of
creating one internally.

**Design change**:

```swift
static func writerLoopSync(
    writer: any RecordingFileWriter,
    format: AVAudioFormat,
    audioBuffers: [SPSCRingBuffer<Float>],
    writeBuffer: AVAudioPCMBuffer,  // ← pre-allocated
    control: WriterControl,
    ...
) {
    while true {
        ...
        let result = flushChunk(
            size: bufferSize,
            from: audioBuffers,
            in: format,
            to: writer,
            using: writeBuffer  // ← reused
        )
        ...
    }
}
```

**Files changed**:
- `AIOEngine+Recording.swift` (`startFileWriteLoop`, `writerLoopSync`, `flushChunk`)

**Risk**: Low. Buffer reuse is safe because the writer loop is single-threaded. The buffer
is written to, then consumed by `writer.write()`, then overwritten on the next iteration.

**Testing**: Existing writer tests cover the write path. Add a test that verifies buffer
reuse doesn't corrupt data (write → read → write → read pattern).

---

### 4.4 [P2] Document Thread Domain Contracts

**Goal**: Make the threading model explicit and compiler-verifiable where possible.

**Approach**:

1. Add a `// MARK: - Thread Domain` section to `AIOEngine.swift` documenting each
   domain, which methods belong to it, and the synchronization mechanism
2. Add `dispatchPrecondition` assertions for methods that must run on specific queues
3. Add `@MainActor` to any public methods currently missing it that should be MainActor
4. Consider a `ThreadDomain` documentation enum (purely for documentation, not runtime):

```swift
/// Documents the intended thread domain for each method and property.
///
/// - `mainActor`: UI thread. Observable state, lifecycle, AVAudioSession configuration.
/// - `engineControl`: Serial queue. All AVAudioEngine graph mutations.
/// - `tapCallback`: Semi-RT thread. Audio processing, lock-free writes.
/// - `writerQueue`: Serial queue. File I/O only.
/// - `receiverQueue`: Serial queue. Visualization consumer.
enum ThreadDomain {
    case mainActor
    case engineControl
    case tapCallback
    case writerQueue
    case receiverQueue
}
```

5. Add `dispatchPrecondition(.onQueue(engineControlQueue))` at the top of closures
   dispatched to the engine control queue (DEBUG-only)

**Files changed**:
- `AIOEngine.swift` (documentation + preconditions)
- `AIOEngine+Recording.swift` (preconditions in writer/receiver loops)
- `AIOEngine+TapSetup.swift` (preconditions in engine control closures)
- `AIO.docc/SPEC_AIO.md` (add threading section)

**Risk**: Zero production risk (documentation + DEBUG assertions).

---

### 4.5 [P2] Move `configureAudioSessionCategory` to MainActor Context

**Goal**: Align AVAudioSession configuration calls with Apple DTS recommendation to call
from main thread.

**Approach**: The `configureAudioSessionCategory` call inside
`AudioEnvironmentManager.run()` currently runs in a `group.addTask { ... }` block on the
cooperative thread pool. Move it to execute synchronously before entering the task group,
while still on MainActor (since `run()` is `@MainActor`).

**Design change**:

```swift
@MainActor
public func run() async throws(ManagerError) {
    // Configure session category on MainActor BEFORE entering task group
    try Self.configureAudioSessionCategory(env.session, configuration: sessionConfiguration)

    await withThrowingTaskGroup(of: Void.self) { group in
        // ... notification subscription tasks only
    }
}
```

**Files changed**:
- `AudioEnvironmentManager.swift`

**Risk**: Low. Moving a one-time configuration call to execute synchronously on MainActor
before spawning background tasks. The call is fast (< 1ms) and happens during app startup.

---

### 4.6 [P2] Add Notification Thread Safety Documentation

**Goal**: Document the threading contract for AVAudioSession notifications.

**Approach**: Add inline documentation to `AudioEnvironment.Notifications` explaining:

1. Notifications arrive on Apple's internal "AVAudioSession Notify Thread"
2. The `compactMap` closures run on this thread (only parsing, no mutable state)
3. The `for await` consumer in `AudioEnvironmentManager.run()` dispatches to MainActor
4. Handlers passed to engine (`handleRouteChange`, etc.) are `@MainActor`

**Files changed**:
- `AudioEnvironment.swift` (add documentation comments)
- `AudioEnvironmentManager.swift` (add documentation comments)

**Risk**: Zero. Documentation only.

---

### 4.7 [P3] Audio Workgroup Support (Future)

**Goal**: Support `os_workgroup_join` for any custom real-time threads.

**Current applicability**: None. AIO does not create custom real-time threads. AVAudioEngine
manages its own workgroup internally. The `writerQueue` and `receiverQueue` are standard
`DispatchQueue`s that do not need workgroup membership.

**When this becomes relevant**:

1. If AIO drops to Core Audio render callbacks (`AudioUnit` render callbacks)
2. If AIO uses `AVAudioSourceNode` or `AVAudioSinkNode` and spawns helper threads
3. If AIO implements a custom real-time mixer thread (e.g., for the `core-audio-layer-opportunities.md` roadmap)

**Approach when needed**:

- Implement `AURenderContextObserver` on custom Audio Units
- Join the host's workgroup via `os_workgroup_join` for auxiliary render threads
- Use `renderContextObserver` property to receive workgroup changes
- Test at buffer sizes < 512 samples to verify correct core scheduling

**Files changed**: N/A (future work)

**Risk**: N/A

---

### 4.8 [P3] Lock-Free Atomic Slot for Tap State (Full Implementation)

**Goal**: Replace the `withLockIfAvailable` fallback approach (§4.1) with a fully
lock-free atomic reference swap, similar to TAAE's `AEManagedValue`.

**When this becomes relevant**: If profiling reveals contention on the
`withLockIfAvailable` path, or if AIO adopts `AVAudioSourceNode`/`AVAudioSinkNode` where
the callback runs on the actual real-time render thread.

**Approach**:

- Implement a triple-buffer with `ManagedAtomic<Int>` index
- Writer (configuration thread) writes to the next free slot and atomically advances the
  index
- Reader (tap thread) reads the current slot without any lock or atomic write
- Old slots are recycled by the writer, not the reader (avoids deallocation on tap thread)

**Inspiration**: TAAE's `AEManagedValue` and the `MultiBandLODProcessor` triple-buffer
already in the codebase.

**Files changed**: `Tools/Async/` (new `AtomicSlot<T>` type), `AIOEngine+Recording.swift`

**Risk**: Low but requires careful memory management to avoid use-after-free.

---

## 5. Implementation Plan

### Phase 1: Safety and Diagnostics (P1)

1. **Tap thread safety assertions** (§4.2)
   - Add `TapThreadChecker` to `AIOEngine`
   - Wire into `processAudio()` under `#if DEBUG`
   - Add to existing test infrastructure

2. **Replace mutex with `withLockIfAvailable` in tap** (§4.1, simpler variant)
   - Add `TapSnapshot` struct
   - Cache last-known-good snapshot in a `nonisolated(unsafe)` property
   - In `processAudio()`: try `withLockIfAvailable` first, fall back to cached snapshot
   - Update snapshot on successful lock acquire
   - Update `applyTapInstallResult` to also update the cached snapshot

### Phase 2: Performance and Documentation (P2)

3. **Pre-allocate write buffer** (§4.3)
   - Create buffer in `startFileWriteLoop`, pass to `writerLoopSync`
   - Modify `flushChunk` to accept pre-allocated buffer

4. **Document thread domain contracts** (§4.4)
   - Add `// MARK: - Thread Domain` sections
   - Add `dispatchPrecondition` assertions
   - Update `SPEC_AIO.md` with threading section

5. **Move session category config to MainActor** (§4.5)
   - Restructure `run()` in `AudioEnvironmentManager`

6. **Add notification threading documentation** (§4.6)
   - Document in `AudioEnvironment.swift` and `AudioEnvironmentManager.swift`

### Phase 3: Future Architecture (P3)

7. **Full lock-free atomic slot** (§4.8) — if profiling warrants
8. **Audio Workgroup support** (§4.7) — if architecture evolves to Core Audio layer

---

## 6. Risk Assessment

### What Could Go Wrong

| Change | Risk | Mitigation |
|---|---|---|
| `withLockIfAvailable` fallback | Stale converter used briefly after route change | Converter remains valid until engine stop/reset; brief staleness causes no audible issue |
| Pre-allocated write buffer | Buffer corruption if writer code path changes | Writer loop is single-threaded; buffer is exclusively owned |
| Thread assertions | False positives in tests | Gate on `ProcessInfo.processInfo.environment` flag |
| Session category move | Subtle ordering change | Category was already set before activation; just moving it earlier in the same sequence |

### What We're NOT Changing

- **No C/C++ render code**: The reference recommends C/C++ for render callbacks. AIO's
  tap callback is Swift, but taps don't run on the render thread. The Swift code in
  `processAudio()` is appropriate for the semi-RT context. Moving to C/C++ would add
  significant complexity with marginal benefit.

- **No custom ring buffer replacing `SPSCRingBuffer`**: The current implementation is
  correct and performant. It uses atomic indices with proper acquire/release ordering. The
  reference mentions `TPCircularBuffer` (virtual memory mapping trick), but this is an
  optimization for avoiding wrap-around branches — AIO's bitmask approach is already
  branch-minimal and more portable.

- **No `AVAudioSourceNode`/`AVAudioSinkNode` adoption**: The reference notes these run
  on the actual render thread. AIO's architecture (tap → ring buffer → writer) is
  appropriate for a recording app. Source/sink nodes would be relevant for a VoIP or
  live-monitoring app.

- **No AUGraph adoption**: The reference mentions AUGraph's documented thread-safe
  reconfiguration. AUGraph is deprecated (since WWDC 2019). AVAudioEngine inherits its
  architecture and AIO correctly uses it through the serial queue pattern.

---

## 7. Testing Strategy

### Existing Coverage

AIO has strong test coverage for the audio pipeline:

- `AIOEngineIntegrationTests` — end-to-end recording with file output, buffer delivery,
  stereo recording, interruption handling, route change fault injection
- `AIOEngineReceiverTests` — queue isolation, timing packet ordering, backpressure
- `SPSCRingBufferTests` — write/read/wrap semantics, drop behavior
- `MultiBandLODTests` — concurrent access (1000+ iterations, 4+ readers)

### New Tests Needed

1. **Tap thread identity assertion test**: Verify `TapThreadChecker` fires on wrong thread
2. **Lock-free tap state test**: Verify `processAudio` continues functioning when lock is
   held by another thread (simulated via `DispatchSemaphore` blocking the main thread
   inside `state.withLock`)
3. **Write buffer reuse test**: Verify pre-allocated buffer produces identical output to
   per-call allocation
4. **Thread domain precondition tests**: Verify `dispatchPrecondition` assertions fire
   correctly in DEBUG

### Performance Validation

- Run `AudioVisualizationTests` performance benchmarks before and after changes
- Measure tap callback latency distribution with and without lock-free path
- Use Instruments (System Trace) to verify no priority inversion events during route
  changes while recording

---

## 8. Appendix: Reference Document Alignment Matrix

| Reference Recommendation | AIO Status | Gap | Priority |
|---|---|---|---|
| Serial configuration queue for AVAudioEngine | ✅ Implemented | None | — |
| Lock-free SPSC ring buffers (tap → consumer) | ✅ Implemented | None | — |
| Atomic state flags for cross-thread communication | ✅ Implemented | None | — |
| No locks on render/tap thread | ⚠️ Partial | `state.withLock()` in `processAudio` | P1 |
| No allocations on render/tap thread | ⚠️ Partial | `AVAudioConverter.convert()` may alloc internally (unavoidable) | Info |
| Pre-allocated buffers for processing | ✅ Implemented | `flushChunk` allocates per-call (not on tap thread) | P2 |
| Configure-early, activate-late session pattern | ✅ Implemented | None | — |
| Session config from main thread | ⚠️ Partial | One call site in `run()` task group | P2 |
| Notification dispatch to desired queue | ✅ Implemented | MainActor via `for await` | — |
| Runtime RT-safety assertions | ❌ Missing | No tap thread checker | P1 |
| Audio Workgroups (iOS 14+) | ❌ Missing | Not needed for current architecture | P3 |
| C/C++ render code | ❌ Not applicable | Taps are not hard-RT; Swift is acceptable | — |
| Thread domain documentation | ⚠️ Partial | Code comments but no formal spec | P2 |
| WebRTC-style thread checkers | ❌ Missing | No compile-time or runtime thread affinity | P1 |
| TAAE-style `AEManagedValue` for atomic reference swap | ❌ Missing | Uses mutex instead | P3 |
| `TPCircularBuffer` (VM-mapped) | ❌ Alternative | `SPSCRingBuffer` with bitmask is equivalent | — |
