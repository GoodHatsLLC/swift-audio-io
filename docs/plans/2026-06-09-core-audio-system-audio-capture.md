# Core Audio system audio capture integration plan

Status: proposed (revised after design review)

> Revision note: this plan was revised after a multi-perspective review against the
> real `swift-audio-io` runtime, Recorder's reference implementation, and the macOS 26.5
> SDK headers. The revision (a) replaces the vague IOProc handoff with a concrete
> realtime-safe design that reuses the existing capture pipeline unchanged, (b) closes
> the four load-bearing integration seams between the new backend and the existing
> runtime (active-backend dispatch, tap-source-ASBD→converter wiring, OSStatus→`isTransient`
> retry gate, IOProc timing capture), and (c) expands the public surface per resolved
> decisions: process selection is object-ID-first **with a public discovery API**,
> `tapName`/`aggregateDeviceUIDPrefix` stay configurable, and the reconciliation start
> API is promoted to public. The package targets macOS 26 / iOS 26 (`Package.swift`), so
> `CATapDescription.bundleIDs` / `processRestoreEnabled` (macOS 26+) and the process-tap
> APIs (macOS 14.2+) need no `@available` gates.

## Implementation status

Landed on `main` (each step build- and test-gated; microphone behavior verified
byte-for-byte; 214 unit tests pass, build clean):

- **Phase 1 — public configuration surface (done).** `RecordingInput` /
  `MicrophoneRecordingInput`; source-specific `RecordingConfiguration` with a
  `format` accessor and a migration convenience initializer; macOS
  `SystemAudioRecordingInput` / `SystemAudioProcessSelection` /
  `SystemAudioProcessObjectID`; the object-ID-first **process discovery API**
  (`SystemAudioProcess`, `SystemAudioProcessCatalog`, PID→object translation);
  new `RecordingError` cases + the OSStatus→`isTransient` retry classifier; the
  reconciliation start API promoted to public. Exports + API snapshot updated.
- **Phase 2 — backend boundary (done).** `RecordingCaptureBackend` +
  `RecordingState.activeBackend`; `hardStop`/`gracefulStop`/`cleanUp` dispatch on
  the active backend; `cleanUp()` is the single idempotent teardown point.
- **Phase 3 — Core Audio backend (done, on-device validation pending).** The
  realtime-safe lock-free handoff (`SystemAudioSampleHandoff`: IOProc-side memcpy
  + timing capture, pump-side rebuild) is **unit-tested** (samples + host/sample
  time round-trip; drop-on-full never blocks). `CoreAudioTapDescriptionBuilder`
  is **unit-tested**. `CoreAudioProcessTapSession` + `CoreAudioSystemAudioBackend`
  (tap/aggregate/IOProc + non-realtime source pump) compile clean.
- **Phase 4 — lifecycle wiring (done, on-device validation pending).** `warm()` /
  `startRecording` route `.systemAudio` through the backend and the shared
  converter/writer/receiver/timing pipeline; mono/stereo channel validation is
  unit-tested.

Pending (require a real macOS audio session + `NSAudioCaptureUsageDescription` +
TCC permission, which CI/unit tests cannot provide — the Phase 0 spike and the
Phase 5 smoke test):

- On-device verification that tap creation prompts for the system-audio
  permission, samples flow end-to-end into a non-empty playable file, self
  exclusion prevents feedback, and cleanup leaves no aggregate devices/taps.
- Confirm the IOProc-delivered source format/channel layout/timing fields and
  `recordingTimingSnapshot()` against a live tap.
- `rotateRecordingFile` / route-change behavior under a live system-audio backend.
- **Phase 5 — demo + Recorder adoption** (`Examples/AudioIODemo` system-audio
  mode; pointing Recorder at this implementation and deleting its app-local
  recorder) — separate target/repo, not yet started.

## Goal

Move Recorder's macOS Core Audio system-audio capture capability into
AudioIO itself, so Recorder and other host apps can select system audio through
the normal `AIOEngine` recording surface instead of carrying a separate
app-local recorder.

The preferred architecture is source-specific capture behind the existing
`AIOEngine` lifecycle:

- `AIOEngine.startRecording(configuration:)` remains the main entry point.
- AudioIO owns file writing, events, buffer receivers, rotation, stop/drain
  semantics, and timing snapshots for both microphone and system audio.
- Recorder keeps product behavior: source picker UI, user messaging,
  persistence, Live Activity coordination, location metadata, and app-specific
  permission copy.

## Current state

AudioIO's recording path is microphone/input-node based:

- `RecordingConfiguration` defines input/output/tap/output destination.
- `AIOEngine.startRecording(configuration:)` warms the engine, installs an
  `AVAudioEngine` input tap, starts writer and receiver loops, emits lifecycle
  events, and returns the output URL.
- `RecordingEngineRuntime.processAudio` converts tap buffers into the package's
  ring-buffer pipeline, which then feeds file writing and live receivers.

Recorder's macOS system-audio path is separate from `AIOEngine`:

- `MacOSSystemAudioRecorder` creates a Core Audio process tap.
- It adds the tap to a private aggregate device.
- It registers and starts an IOProc.
- It copies Core Audio buffers, processes them on a serial queue, writes its own
  output file, and emits live receiver buffers through its own receiver list.
- `RecordingService` branches around this service for start, stop, and live
  waveform attachment.

That proves the Core Audio approach, but the duplicated writer/receiver path is
not the shape AudioIO should publish.

## Non-goals

- No SwiftUI, AppKit, or source-picker UI.
- No Recorder persistence, background processing, Live Activity, or location
  metadata.
- No ScreenCaptureKit fallback unless a concrete supported macOS target requires
  it.
- No general DSP, effects, editing, or mixing behavior.
- No hard-coded Recorder names, bundle identifiers, logger categories, or
  product copy.

## Public API shape

`.systemAudio` should be public immediately, not gated behind `@_spi(Advanced)`.
This is a pre-1.0 package and the feature is engine-level capability, not a
Recorder-only escape hatch.

Make this a breaking configuration cleanup rather than adding a generic
`tapInterval` that only applies to microphone capture. The source-specific
configuration should be an enum so callers can only provide options that make
sense for the selected source:

```swift
public struct RecordingConfiguration: Hashable, Sendable {
  public var input: RecordingInput
  public var outputConfiguration: OutputConfiguration
  public var outputDestination: OutputDestination

  // Source-agnostic accessor. The file-format machinery (processingFormat,
  // fileSettings, fileFormat, tapConfiguration, channel validation,
  // description/summary/debugDescription) reads `format` instead of the old
  // stored `inputConfiguration`, so it stays source-agnostic after the refactor.
  public var format: InputConfiguration { input.format }
}

public enum RecordingInput: Hashable, Sendable {
  case microphone(MicrophoneRecordingInput)
  #if os(macOS)
    case systemAudio(SystemAudioRecordingInput)
  #endif

  // The requested processing format (sample rate + channels) is common to both
  // sources, so callers and the file pipeline can read it without unwrapping.
  public var format: InputConfiguration {
    switch self {
    case .microphone(let mic): mic.format
    #if os(macOS)
      case .systemAudio(let system): system.format
    #endif
    }
  }
}

public struct MicrophoneRecordingInput: Hashable, Sendable {
  public var format: InputConfiguration
  public var tapInterval: Duration
}

#if os(macOS)
public struct SystemAudioRecordingInput: Hashable, Sendable {
  public var format: InputConfiguration
  public var processSelection: SystemAudioProcessSelection
  /// Excludes the host process from the tap so the recorder never captures its
  /// own output (prevents feedback). Default `true`. Explicit (not implicit in
  /// the implementation) so "default excludes the current process" is a
  /// predictable, testable property of the public model.
  public var excludesCurrentProcess: Bool
  /// Human-readable `CATapDescription.name`. Defaulted by the factory.
  public var tapName: String
  /// Reverse-domain prefix for the private aggregate device UID. AudioIO appends
  /// a unique UUID suffix per session, so the prefix only namespaces the device;
  /// collisions are avoided by the suffix. Defaulted by the factory.
  public var aggregateDeviceUIDPrefix: String
}

public struct SystemAudioProcessSelection: Hashable, Sendable {
  public enum Mode: Hashable, Sendable {
    case includeOnly   // tap only the listed processes (CATapDescription mixdown of processes)
    case exclude       // tap everything except the listed processes (global, exclusive)
  }

  public var mode: Mode
  public var processObjectIDs: [SystemAudioProcessObjectID]
  public var bundleIdentifiers: [String]
  public var restoresProcessesByBundleIdentifier: Bool
}

public struct SystemAudioProcessObjectID: RawRepresentable, Hashable, Sendable {
  public var rawValue: UInt32   // AudioObjectID

  /// The host process's audio object, resolved via the HAL
  /// (`kAudioHardwarePropertyTranslatePIDToProcessObject`). `nil` when the HAL
  /// has no audio object for the process yet. See "Process selection and discovery".
  public static var currentProcess: SystemAudioProcessObjectID? { get }
  /// Translate a known PID to its audio object ID via the HAL. `nil` on failure.
  public init?(processID: pid_t)
}

/// A capturable process discovered from the HAL, so callers can build include /
/// exclude selections without already knowing raw AudioObjectIDs.
public struct SystemAudioProcess: Hashable, Sendable, Identifiable {
  public var id: SystemAudioProcessObjectID
  public var processID: pid_t
  public var bundleIdentifier: String?
  public var name: String?
}

public enum SystemAudioProcessCatalog {
  /// Enumerate processes the HAL currently exposes as audio sources
  /// (`kAudioHardwarePropertyProcessObjectList` + per-object metadata).
  public static func capturableProcesses() throws(RecordingError) -> [SystemAudioProcess]
}
#endif
```

Notes:

- Keep `InputConfiguration` as the requested processing format inside each
  source-specific input: sample rate and channel count still describe the output
  pipeline.
- On macOS, `.systemAudio` supports mono and stereo only — global process taps
  are mono or stereo mixdowns (`CATapDescription` mono/stereo initializers). This
  is a hard constraint, not a default: `warm()` must reject `.systemAudio` with a
  requested channel count > 2 via `RecordingError.unsupportedChannelCount(requested:maximum: 2)`
  before starting the backend, because the existing `validateRecordingChannelCapacity`
  only checks an upper bound (32 / format max), not a source-specific cap.
- `MicrophoneRecordingInput` owns `tapInterval`; system audio does not expose
  `tapInterval` because HAL IO cadence is not the same concept as an
  `AVAudioEngine` input-node tap interval.
- Preserve migration ergonomics with convenience initializers or static factories
  such as `.microphone(format:tapInterval:)` and
  `.systemAudio(format:processSelection:)`, but make the stored model
  source-specific.
- Host apps still own `NSAudioCaptureUsageDescription` in their app bundle.
  AudioIO should document that requirement, not try to supply it.
- **Configuration refactor is not just additive.** `RecordingConfiguration`
  currently stores `inputConfiguration` and a top-level `tapInterval`, and ~10
  members read them directly (`processingFormat`, `fileSettings`, `fileFormat`,
  `tapConfiguration(bus:input:)`, `commonFormat`, `description`, `summary`,
  `debugDescription`, channel validation in `RecordingEngineRuntime`). All must
  move to the source-agnostic `format` accessor. Land the config refactor as a
  **standalone PR ahead of any system-audio code**, gated on the full microphone
  test suite, so Phase 2's "microphone behavior byte-for-byte equivalent" is
  verifiable in isolation. In particular `updateRecordingTapInterval`
  reconstructs a `RecordingConfiguration` with the old initializer
  (`RecordingConfiguration(inputConfiguration:outputConfiguration:tapInterval:outputDestination:)`)
  and will not compile post-refactor — replace it with a `.microphone`-case
  pattern-match that rebuilds `MicrophoneRecordingInput` with the new interval,
  and make it a no-op for `.systemAudio` (system audio has no tap interval).
- Add all new public symbols to `Sources/AudioIO/Exports.swift` (curated
  `public typealias` re-exports) and `Tests/AIOTests/PublicAPISnapshot.swift`
  (compile-time pins). Concretely: `RecordingInput`, `MicrophoneRecordingInput`,
  and `#if os(macOS)`-gated `SystemAudioRecordingInput`, `SystemAudioProcessSelection`
  (and its nested `Mode`), `SystemAudioProcessObjectID`, `SystemAudioProcess`,
  `SystemAudioProcessCatalog`. The snapshot must compile on both iOS (macOS
  symbols excluded by the gate) and macOS.
- **Promote the reconciliation start API to public** (resolved decision). Today
  `setDesiredRecordingState` / `startRecordingWithReconciliation` are
  `@_spi(Advanced)` and `AIORecording` is re-exported `@_spi(Advanced)` from
  `Sources/AudioIO/Exports.swift`; the `RecordingDriving` protocol is likewise
  SPI-gated. Promotion must drop `@_spi(Advanced)` from these symbols, the
  protocol, and the re-export line, and add them to the public API snapshot.
  Audit for other members that ride the same `@_spi(Advanced) @_exported import
  AIORecording` line so nothing else is unintentionally promoted.

### Process selection and discovery

Expose include and exclude process filters in the first public system-audio API
and test them. The local macOS 26.5 SDK confirms that `CATapDescription`
supports:

- process object IDs for include/exclude lists (`processes`),
- bundle identifiers (`bundleIDs`, macOS 26+),
- process restore by bundle identifier (`isProcessRestoreEnabled`, macOS 26+),
- mono and stereo global taps,
- device UID and stream-specific tap initializers.

The initial public AudioIO surface covers global include/exclude by process
object ID and bundle identifier. Device UID and stream-specific capture stay out
of the first API unless manual validation shows they are required; the
implementation must be shaped so device-specific capture can be added without
another model rewrite.

**Process discovery is part of the first public API** (resolved decision:
object-ID-first with discovery). Raw `AudioObjectID`s are opaque and
undiscoverable to external callers, so AudioIO ships:

- `SystemAudioProcessObjectID.currentProcess` and `init?(processID:)`, which
  translate the host PID (or any PID) to an audio object via
  `kAudioHardwarePropertyTranslatePIDToProcessObject`.
- `SystemAudioProcessCatalog.capturableProcesses()`, which enumerates HAL audio
  processes (`kAudioHardwarePropertyProcessObjectList`) with per-object metadata
  (`kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`) into
  `[SystemAudioProcess]`.

These port the process-lookup logic Recorder hides in its private
`AudioHardwareSystem` wrapper into **public** AudioIO surface. They belong in
`AIOAudioSession` next to the existing HAL property plumbing in
`Sources/AIOAudioSession/Env/PlatformAudioBackend.swift` (which already reads
`kAudioObjectSystemObject` properties), and are re-exported through `AudioIO`.
The enumeration call is `throws(RecordingError)` so HAL failures map to the
package error model rather than raw `OSStatus`.

Self-exclusion is modeled explicitly via
`SystemAudioRecordingInput.excludesCurrentProcess` (default `true`). When set,
the implementation resolves `SystemAudioProcessObjectID.currentProcess` and adds
it to the exclusion set; if that lookup fails it falls back to bundle-identifier
exclusion (see the retry table's "process lookup fails" row). This makes the
"default excludes the current process" behavior a property of the model, not a
hidden implementation detail.

Test expectations:

- default system audio (`excludesCurrentProcess == true`) excludes the current
  process, and the exclusion survives a `currentProcess` lookup failure by
  falling back to the host bundle identifier,
- include-only by process object ID builds an include (mixdown) tap description,
- exclude by process object ID builds an exclusive/global tap description,
- include-only by bundle identifier sets `bundleIDs` and restore behavior,
- exclude by bundle identifier sets `bundleIDs`, `exclusive`, and restore
  behavior,
- mixed process-object and bundle-ID filters produce a deterministic tap
  description or fail validation if the SDK cannot represent the combination,
- `SystemAudioProcessObjectID(processID:)` round-trips a known PID, and
  `capturableProcesses()` returns the host process with a matching bundle ID
  (host-test, behind the system-audio permission).

## Error model

Prefer extending `RecordingError` rather than adding a Recorder-style parallel
error enum. Candidate cases:

```swift
case captureSourceUnavailable(details: String)
case captureSourceFailed(sourceDescription: String, details: String)
```

Use a source description string rather than embedding the full source enum in
the error. That avoids leaking potentially large or platform-conditional
configuration into equality, error output, and future ABI shape. Core Audio
OSStatus values should be wrapped into stable, readable `RecordingError` values
rather than escaping as raw framework errors. Add a catch-all
`case coreAudioFailed(operation: String, osStatus: Int32, details: String)` for
unmapped statuses so failures are always surfaced (logged with operation context
and emitted via `AudioIOEvent.error`) rather than silently swallowed.

### Wiring retries into `isTransient` (do not skip)

The reconciliation loop retries **only** when the caught error's
`RecordingError.isTransient == true` (`RecordingRuntime.reconcileRecordingState`),
and `isTransient` is currently `true` only for `.session(sessionError)` where
`SessionError.isTransient` holds (today: `.notReady`). A standalone
"OSStatus→retry" classifier that does not feed this property is dead code: a
retryable `kAudioHardwareNotReadyError` would be classified retryable and then
**never retried**. The classifier must therefore be production code that decides
which `RecordingError` an OSStatus maps to:

- **Retryable HAL statuses** (per the table below) map to
  `.session(.notReady(details:))`, reusing the existing transient gate
  unchanged. (If `.notReady` reads wrong for a HAL cause, add a sibling
  `SessionError` case whose `isTransient` is `true`.)
- **Terminal source failures** map to `captureSourceUnavailable` /
  `captureSourceFailed` / `coreAudioFailed`, whose `isTransient` is `false`
  (the default for non-`.session` cases — keep it that way).

This makes the retry decision a single source of truth: the OSStatus→`RecordingError`
mapping. Unit-test it against every row of the table below by asserting the
mapped error's `isTransient` matches the table's retry column.

## Reconciliation retry investigation

System audio should participate in reconciliation retry, but only for a narrow,
explicit set of startup failures. The retry decision must happen before user
state is marked recording and must fully clean up any partially created Core
Audio objects before the next attempt.

Investigation inputs:

- Context7 did not return focused Apple Core Audio process-tap documentation for
  this API family; implementation planning is based on the local Xcode 26.5 /
  macOS 26.5 SDK headers and Recorder's current working code path.
- `AudioHardwareCreateProcessTap` creates a tap from `CATapDescription` and
  returns an OSStatus.
- `AudioDeviceCreateIOProcIDWithBlock` retains the dispatch queue and block until
  `AudioDeviceDestroyIOProcID`; if no queue is supplied, the block is invoked
  directly.
- `AudioDeviceStart` and `AudioDeviceStop` return only OSStatus.
- The HAL error constants documentation says HAL functions can return codes not
  listed in the header, and any non-zero status is a failure.
- Relevant HAL constants include `kAudioHardwareNotRunningError`,
  `kAudioHardwareNotReadyError`, `kAudioDevicePermissionsError`,
  `kAudioHardwareUnsupportedOperationError`, object/device/stream errors, bad
  property errors, illegal operation, unspecified error, and unsupported format.

Retry classification:

| Failure | Retry? | Rationale |
|---|---:|---|
| `kAudioHardwareNotReadyError` while creating tap, aggregate device, IOProc, or starting IO | Yes, bounded | HAL explicitly describes the object as not ready. Treat like AudioIO's existing transient session-not-ready case. Cleanup and retry with reconciliation backoff. |
| Aggregate device creation returns success but no usable device | Yes, bounded | Equivalent to not-ready for this startup attempt, provided every created tap/device is destroyed before retry. |
| `kAudioHardwareNotRunningError` during stop/cleanup | No start retry; cleanup-tolerant | During cleanup this can mean the device was already stopped. Continue destroying IOProc, aggregate device, and tap; report only if final cleanup cannot complete. |
| `kAudioDevicePermissionsError` | No | User or system permission is required. Retrying without user action is noise. Surface a terminal recording failure. |
| `kAudioHardwareUnsupportedOperationError` or `kAudioDeviceUnsupportedFormatError` | No | Configuration or platform capability mismatch. Caller must change source/options/format. |
| `kAudioHardwareBadObjectError`, `kAudioHardwareBadDeviceError`, `kAudioHardwareBadStreamError` | No | Stale or invalid object IDs. For process filters, caller must refresh process selection. |
| `kAudioHardwareUnknownPropertyError` or `kAudioHardwareBadPropertySizeError` | No | Implementation/SDK mismatch. Retrying should not fix it. |
| `kAudioHardwareIllegalOperationError` | No by default | Usually invalid operation ordering or unsupported state. Log operation context and fail; only reclassify after a reproduced transient case. |
| `kAudioHardwareUnspecifiedError` or unknown OSStatus | No by default | The header warns that non-zero statuses are failures but does not establish retryability. Do not hide repeated failures behind loops. |
| Process lookup for current process fails | No | Fall back to bundle identifier exclusion when available; otherwise start with the configured filters and record the degraded exclusion behavior. |
| Target process in an include filter exits before start | No | The include filter is no longer valid. Bundle-ID restore can cover future launches when configured; process-object retry cannot resurrect an exited process. |
| File writer, converter, or output URL failure | No | These are AudioIO configuration or filesystem failures, not Core Audio readiness. |

Runtime failure policy:

- Startup retry applies before `recordingStarted` is emitted. This matches
  existing behavior: `startRecording` emits `.recordingStarted` only after a
  successful start, inside the reconcile loop's `do/catch`, so retries never
  reach emission. Restate this as confirming existing behavior so it is not
  "fixed" into a regression.
- **Cleanup must run between retry attempts.** Every retryable failure must fully
  destroy any partially created Core Audio objects before the next attempt, the
  same way the microphone path's `warm()` failure calls `hardStop()`. Concretely:
  the system-audio `warm()`/start path wraps backend bring-up in a `do/catch`
  that calls `backend.cleanup()` before rethrowing, so the error reaching
  `reconcileRecordingState` always leaves a clean slate. `cleanup()` is
  best-effort and non-throwing (see "Core Audio backend design"), with a fixed
  teardown order: (1) `AudioDeviceStop` (tolerate `kAudioHardwareNotRunningError`),
  (2) `AudioDeviceDestroyIOProcID`, (3) destroy aggregate device, (4) destroy
  process tap — capturing the first non-zero status but always continuing.
- After recording has started, Core Audio backend failures should emit the same
  AudioIO error/recording-failed events as microphone tap failures and stop the
  active recording.
- Do not auto-restart a running system-audio recording after a post-start HAL
  failure until manual validation proves that restart is safe and does not
  duplicate or truncate user audio unexpectedly.
- The OSStatus-to-retry classifier is **production code** (it determines which
  `RecordingError` an OSStatus maps to, which in turn drives `isTransient` — see
  "Wiring retries into `isTransient`"), not a test-only helper. Unit-test every
  row above by asserting the mapped `RecordingError.isTransient` equals the
  row's retry decision.

## Internal architecture

Introduce an internal source backend boundary in `AIORecording`:

```swift
package protocol RecordingCaptureBackend: Sendable {
  /// The native capture format of this source:
  /// - microphone: the `AVAudioEngine.inputNode` post-install format.
  /// - system audio: the tap ASBD from `kAudioTapPropertyFormat`.
  /// Common code builds the `sourceFormat → processingFormat` converter from this.
  var sourceFormat: AVAudioFormat { get }

  /// Begin delivering buffers. The backend never converts, writes files, or
  /// calls receivers; it feeds the common pipeline (directly for microphone via
  /// `processAudio`, or via the realtime-safe handoff + source pump for system
  /// audio — see "Core Audio backend design").
  func start() throws(RecordingError)

  /// Stop delivering buffers (no teardown of long-lived objects required here
  /// beyond what is needed to halt delivery).
  func stop() throws(RecordingError)

  /// Best-effort, non-throwing teardown of all owned resources, safe to call
  /// after a partial `start()`. Microphone: remove the input tap, stop/reset the
  /// engine. System audio: stop IO, destroy IOProc, aggregate device, and tap in
  /// that order. Idempotent.
  func cleanup()
}
```

The exact protocol shape can change during implementation. The important splits:

- **Common recording setup owns** output URL resolution, writer creation,
  ring-buffer allocation, receiver timing, event emission, state bookkeeping,
  **and the converter artifacts** (`tapConverter`, `tapConverterInputFormat`,
  `tapConverterOutputFormat`, `tapConvertedBuffer` in `RecordingState`, updated
  atomically under `tapSnapshotLock` via `applyTapInstallResult`). Backends vend
  only `sourceFormat`; common code builds the converter and pre-allocates the
  converted buffer. This avoids a stale converter in `processAudio` after a
  backend swap and a double-free if both sides tried to release it. `cleanUp()`
  clears the converter artifacts exactly as it does today.
- **Microphone backend owns** the existing `AVAudioEngine` input tap install/start.
  The tap-removal + engine stop/reset currently inlined in `hardStop()` /
  `gracefulStop()` must move behind `cleanup()`/`stop()` on the microphone
  backend so the lifecycle methods dispatch uniformly. Microphone behavior must
  remain byte-for-byte equivalent (Phase 2).
- **System-audio backend owns** the Core Audio tap, aggregate device, IOProc, the
  realtime-safe handoff buffers, and their teardown.

### Active-backend state and dispatch

`RecordingState` (in `RecordingSupportTypes.swift`) gains an active-backend
discriminant — concretely `package var activeBackend: (any RecordingCaptureBackend)?`
(plus, if useful for logging, a lightweight `sourceKind` enum). It is set after
`warm()` succeeds in `startRecording`, and cleared by `cleanUp()`.

Every teardown/lifecycle site must dispatch on it rather than hardcoding the
`AVAudioEngine` path it uses today:

- `hardStop()` and `gracefulStop()` currently call
  `engine.inputNode.removeTap(onBus:)`, `engine.stop()`, `engine.reset()`
  unconditionally. They must instead route to `activeBackend?.cleanup()` /
  `stop()`. For `.systemAudio` this destroys IOProc/aggregate/tap; calling
  `removeTap` on a never-installed input node, or running the AVAudioEngine for a
  source that never used it, is wrong and leaks HAL objects on every stop.
- The `warm()`/start failure path must clean up the partially-initialized backend
  (see "Runtime failure policy").
- Route-change handling (microphone-only today) stays microphone-only; system
  audio's device-change behavior is defined under "Route and device changes".

Without this discriminant, a *stop-mic-then-start-system-audio* sequence tears
down the wrong backend. Add a test asserting `engine.inputNode.removeTap` is
never invoked during system-audio teardown.

## Core Audio backend design

> Scoping correction: this is **not** a pure "move" of Recorder code. Recorder's
> `MacOSSystemAudioRecorder` depends on an `AudioHardwareSystem` / `AudioHardwareTap`
> / `AudioHardwareAggregateDevice` wrapper layer (`makeProcessTap`,
> `makeAggregateDevice`, `process(for:)`, `destroyProcessTap`, …) that is **neither
> an Apple SDK symbol nor present in tracked Recorder source**. Those wrappers must
> be authored fresh in `AIORecording` as package-internal types, with explicit
> lifecycle ownership (`CoreAudioProcessTapSession` owns tap + aggregate device +
> IOProc). The HAL property reads they need have precedent in
> `Sources/AIOAudioSession/Env/PlatformAudioBackend.swift`. Treat this as new code,
> and the process-discovery half of it (`SystemAudioProcessObjectID` translation,
> `SystemAudioProcessCatalog`) as **public** surface.

De-Recorderize and bring in:

- `CoreAudioProcessTapSession` (owns tap + aggregate device + IOProc lifecycle),
- the `AudioHardware*` wrappers it needs (package-internal, written fresh),
- process exclusion + selection helpers (and the public discovery API above),
- private aggregate device description,
- IOProc creation/start/stop/destruction,
- OSStatus mapping helpers (drive the `RecordingError` mapping + retry classifier).

### Realtime safety: the IOProc is a pure lock-free copy

The IOProc runs on a Core Audio realtime thread. Recorder's reference IOProc is
**not** realtime-safe: it heap-allocates a `Data` per channel per callback
(`SystemAudioSampleChunk.init(copying:)`) and then `DispatchQueue.async`s the
work out — both can block on a malloc/queue lock and must not appear on a
realtime thread. The microphone path never does this: its tap callback only does
atomic increments and lock-free `SPSCRingBuffer<Float>.write()` (which is a
non-overwriting `memcpy` guarded by atomic indices — no allocation, no locks).
The system-audio IOProc must hold the same discipline.

**Hard rules for the IOProc block (non-negotiable):**

- It does pre-allocated, lock-free copies only — `SPSCRingBuffer.write()` into
  buffers allocated before the IOProc is registered.
- No `malloc`/`Data`/array growth, no `DispatchQueue.async`, no locks, no ObjC
  message sends where avoidable, no Swift concurrency (`Task`, actors, `await`).
- No `AVAudioConverter` — conversion can allocate; it happens off the IOProc.
- No file I/O and no calls into app-provided `BufferReceiver`s.
- On a full ring it drops (returns 0) and bumps a drop metric; it never blocks.

### Data path

Setup (off the realtime thread, before `AudioDeviceStart`):

1. Create the tap; read `kAudioTapPropertyFormat` → `sourceFormat: AVAudioFormat`.
2. **Validate `sourceFormat` before starting IO**: linear PCM, sample rate > 0,
   channel count ∈ {1, 2} consistent with the requested `format.channels`. Reject
   compressed/exotic formats with a terminal `RecordingError` *before*
   `recordingStarted` is emitted — never discover a mismatch in the first
   callback (where `processAudio` would silently bail with `.converterMissing`).
3. Discover the aggregate device's IO buffer size:
   `kAudioDevicePropertyBufferFrameSize` (+ `kAudioDevicePropertyUsesVariableBufferFrameSizes`).
   Call this `maxIOFrames`. If unqueryable or zero, fail startup with a
   diagnostic error. System audio has **no** `tapInterval`: the HAL chooses the
   buffer size, and there is no microphone-style `requestTapResize` recovery, so
   everything downstream is pre-sized to `maxIOFrames`.
4. Allocate the lock-free handoff (sized like the mic path, `maxBufferSeconds`
   ≈ 2 s of `sourceFormat`):
   - a raw byte ring `SPSCRingBuffer<UInt8>` for the source payload, and
   - a `SPSCRingBuffer<SystemAudioTimingPacket>` for per-callback timing.
5. Common code builds the `sourceFormat → processingFormat` `AVAudioConverter`
   and pre-allocates the converted buffer (capacity from `maxIOFrames × ratio`),
   and pre-allocates the pump's reusable `sourceFormat` `AVAudioPCMBuffer`
   (capacity `maxIOFrames`). The converter artifacts are installed into
   `RecordingState`/`tapSnapshotLock` **before** the first callback so
   `processAudio`'s `formatsCompatible` checks pass from buffer #1.

IOProc (realtime thread) — bounded and allocation-free:

```swift
// Pseudocode. `bytesPerFrame` is derived once from sourceFormat's ASBD,
// accounting for the non-interleaved flag (see Recorder's SystemAudioInputFormat
// for the exact derivation): interleaved → one buffer of frames*mBytesPerFrame;
// non-interleaved → one buffer per channel, each frames*bytesPerChannel.
// `frames = firstBuffer.mDataByteSize / bytesOfFirstBufferPerFrame`.
//
// All-or-nothing across channels: reserve space for the WHOLE callback first,
// so a non-interleaved list never lands with some channels written and others
// dropped. Push all audio, then the timing packet, so the pump never sees a
// timing packet whose audio bytes are not yet present.
let totalBytes = sum(buffer.mDataByteSize for buffer in inInputData)   // all channels
if byteRing.availableToWrite >= totalBytes {
  for buffer in inInputData { byteRing.write(buffer.asUInt8) }         // lock-free memcpy, in list order
  var packet = SystemAudioTimingPacket(
    frameCount: frames,
    hostTime:   (inInputTime.mFlags.contains(.hostTimeValid))   ? inInputTime.mHostTime  : nil,
    sampleTime: (inInputTime.mFlags.contains(.sampleTimeValid)) ? inInputTime.mSampleTime : nil,
    rateScalar: inInputTime.mRateScalar)
  _ = timingRing.write(/* &packet, count: 1 */)
} else {
  systemAudioDropCount.wrappingIncrement(ordering: .relaxed)          // glitch, never block
}
```

The pump reverses the same framing: it reads `frameCount` from the timing
packet, then reads the matching bytes (one interleaved buffer, or one block per
channel) into the reusable `sourceFormat` `AVAudioPCMBuffer`. Because the IOProc
only ever publishes a timing packet after a complete audio write, the pump's two
reads are always consistent — no per-channel desync, no partial frames.

Source pump (a new non-realtime serial queue, e.g. `sourcePumpQueue`,
`.userInitiated`, with the same idle backoff shape as `writerLoopSync`):

1. Read a `SystemAudioTimingPacket` (learn `frameCount`).
2. Read `frameCount × bytesPerFrame` bytes from the byte ring into the reusable
   `sourceFormat` `AVAudioPCMBuffer` (reconstructing the source channel/interleave
   layout exactly as `sourceFormat` describes — no float assumption baked into
   the IOProc).
3. Rebuild an `AudioTimeStamp` from the packet and wrap it via
   `AVAudioTime(audioTimeStamp:sampleRate:)` (host time is the
   `mach_absolute_time` domain — exactly what `recordingFirstHostTimeAtomic`
   expects; sample-time validity carries through the flags). **No `processAudio`
   signature change is required.**
4. Call the **existing** `processAudio(buffer: sourceBuffer, time: avTime, to:
   processingFormat)`. From here system audio is byte-identical to microphone:
   the shared converter, the per-channel writer/receiver ring buffers,
   `TimingPacket`, `recordingSampleTimeAtomic`, first-host-time anchoring, the
   writer loop, the receiver loop, metrics, and `recordingTimingSnapshot()` all
   apply unchanged.

This interposed ring + pump is the system-audio analog of AVAudioEngine's render
thread: for microphone, AVAudioEngine's (semi-realtime) thread calls
`processAudio` directly; for system audio the HAL IOProc cannot safely run the
converter, so it hands off to the pump, which calls `processAudio` off the
realtime thread. The only net-new runtime piece is the ring + pump; everything
downstream is reused.

### Timing fidelity

The IOProc captures `inInputTime.mHostTime` / `mSampleTime` (gated on the
`kAudioTimeStampHostTimeValid` / `SampleTimeValid` flags) into the handoff
packet, the pump threads them through `AVAudioTime`, and `processAudio` anchors
`recordingFirstHostTimeAtomic` / `recordingFirstSourceSampleTimeAtomic` from the
first valid host time exactly as for microphone. This is a real improvement over
Recorder, which discards `inInputTime` entirely and synthesizes a sample time
with no host time. `TimingPacket` already carries `hostTime` / `sourceSampleTime`
/ `sourceSampleRate`, so no new internal timing type is needed. Note that
system-audio `sourceSampleTime` may not be monotonic across glitches; treat it as
informational, not as the writer's authority (the writer uses
`recordingSampleTimeAtomic`, which is monotonic by construction).

### Cleanup

`CoreAudioProcessTapSession.cleanup()` is best-effort, non-throwing, idempotent,
and survives partial start: stop IO (tolerate `kAudioHardwareNotRunningError`) →
destroy IOProc → destroy aggregate device → destroy process tap, capturing the
first non-zero status but always continuing. It is invoked by `backend.cleanup()`
on every failure and stop path (see "Active-backend state and dispatch").

## Lifecycle integration

Start (inside `warm()` / the start path, before `recordingStarted`):

- Validate source support for the current platform (`.systemAudio` is macOS-only).
- For `.systemAudio`, validate the channel count is mono or stereo
  (`unsupportedChannelCount(requested:maximum: 2)` otherwise).
- Stop active playback using the existing recording-start behavior.
- Resolve output URL and writer using the existing helpers.
- Create the backend; for system audio: create the tap, read + **validate** the
  tap source ASBD, discover `maxIOFrames`, allocate the lock-free handoff rings,
  and create the aggregate device + IOProc (not started yet). Any failure here
  calls `backend.cleanup()` and throws (retryable failures map to
  `.session(.notReady)` so reconciliation can retry on a clean slate).
- Allocate writer and receiver ring buffers (shared pipeline).
- Build the `sourceFormat → processingFormat` converter artifacts (common code)
  and install them under `tapSnapshotLock` before any buffer flows.
- Set `activeBackend` in `RecordingState`.
- Start the source backend (`AudioDeviceStart`) and, for system audio, the source
  pump loop.
- Start writer and receiver loops.
- Emit `.recordingStarted(url:format:)`.
- Set `isRecording` and `wantsRecording` consistently with the microphone path.

Stop:

- Stop the active capture backend first (`activeBackend?.stop()`) so no more
  samples enter the pipeline. For system audio this stops `AudioDeviceStop` and
  the source pump; for microphone it removes the input tap / stops the engine.
- Drain writer sessions through the existing `gracefulStop` path (the source
  pump must have stopped enqueuing first, so the writer drain terminates).
- `activeBackend?.cleanup()` destroys IOProc/aggregate/tap (system audio) and is
  cleared by `cleanUp()`.
- Validate output existence and size.
- Surface write failures through existing `RecordingError.fileFailed` behavior.
- Emit `.recordingCompleted`.

Rotation:

- Reuse `rotateRecordingFile()` unchanged: system-audio samples feed the same
  post-conversion `audioBuffers` ring buffers (the pump calls `processAudio`,
  which writes them), so rotation's writer/buffer swap under `tapSnapshotLock`
  works exactly as for microphone. The backend, IOProc, and source pump are not
  touched by rotation — capture continues uninterrupted.
- Add tests that rotate while a fake system-audio backend is producing buffers.

Microphone tap interval:

- Keep current microphone semantics, but move the value into
  `MicrophoneRecordingInput`.
- Do not expose an equivalent value for system audio. If a future Core Audio
  source option controls HAL buffer cadence, add it as a system-audio-specific
  option with a name that describes that behavior.

Route and device changes:

- Microphone route-change behavior remains unchanged.
- For system audio, start with conservative behavior: keep running unless Core
  Audio reports a backend failure. Add restart-on-device-change only if manual
  validation proves it is needed.

## Test plan

Unit and host tests:

- Public API snapshot includes `RecordingInput`, `MicrophoneRecordingInput`,
  and macOS-only `SystemAudioRecordingInput`, `SystemAudioProcessSelection`
  (+ `Mode`), `SystemAudioProcessObjectID`, `SystemAudioProcess`,
  `SystemAudioProcessCatalog`, plus the now-public reconciliation start API.
- `RecordingConfiguration` hash/equality/description tests cover microphone and
  explicit system audio source configurations, and the source-agnostic `format`
  accessor returns the right `InputConfiguration` for each case.
- Configuration tests prove `tapInterval` is accepted only through
  `MicrophoneRecordingInput`, and `updateRecordingTapInterval` is a no-op for a
  `.systemAudio` configuration (and still recompiles/works for `.microphone`).
- Process-selection tests cover include-only and exclude modes for process
  object IDs and bundle identifiers, and `excludesCurrentProcess` semantics
  (including the bundle-ID fallback when `currentProcess` lookup fails).
- Process-discovery tests: `SystemAudioProcessObjectID(processID:)` round-trips a
  known PID; `SystemAudioProcessCatalog.capturableProcesses()` returns the host
  process with a matching bundle ID (host-test, behind the permission).
- Channel-capacity test: `.systemAudio` with > 2 channels throws
  `unsupportedChannelCount` at `warm()`.
- Retry-classification tests cover every OSStatus row in the reconciliation
  retry investigation by asserting the **mapped `RecordingError.isTransient`**
  equals the row's retry decision (proves the classifier actually drives the
  reconcile loop, not just a standalone table).
- Backend-dispatch test: after start-microphone → stop → start-system-audio,
  `engine.inputNode.removeTap` is never called during system-audio teardown, and
  no aggregate device / tap leaks (assert via the wrapper's destroy counters).
- iOS compilation proves `.systemAudio` is unavailable on iOS.
- Fake backend tests cover:
  - start success emits `.recordingStarted`
  - stop success emits `.recordingCompleted`
  - start failure cleans up partial Core Audio objects (`cleanup()` invoked,
    teardown order respected)
  - tap-source-ASBD mismatch surfaces a terminal error **before**
    `.recordingStarted` (not a silent first-callback `.converterMissing` drop)
  - stop failure maps to `RecordingError`
  - samples flow into writer ring buffers
  - samples flow into attached `BufferReceiver`
  - injecting a known `AudioTimeStamp` makes `recordingTimingSnapshot()` return
    the correct non-zero host time and paired source sample time
  - rotation swaps writers without stopping capture
- Realtime-safety test: drive the fake/real backend for ~10 s and assert the
  IOProc path performs no heap allocation (e.g. malloc-stack/allocation
  instrumentation or a counting allocator hook) and the drop metric stays at 0
  under normal load; an artificially stalled writer increments the drop metric
  rather than blocking.
- Existing microphone tests continue to pass unchanged (gate for the standalone
  configuration-refactor PR).

Manual macOS validation:

- Build a local harness or extend `Examples/AudioIODemo` with a temporary
  system-audio source toggle during development.
- Confirm first capture prompts under the macOS system-audio recording
  permission, not ScreenCaptureKit.
- Confirm the host app needs `NSAudioCaptureUsageDescription`.
- Confirm self-audio exclusion prevents feedback from the host process.
- Confirm cleanup leaves no private aggregate devices or taps behind.
- Confirm the output file is non-empty and plays back.
- After the API lands, keep system-audio recording exposed in
  `Examples/AudioIODemo` as a real demo, not just a temporary harness.

Recommended package commands:

```sh
xcrun swift test
git diff --check
```

Add any repo-specific CI scripts if they exist by implementation time.

## Recorder migration plan

After AudioIO lands and Recorder is pinned to the new version or local checkout:

1. Update Recorder's `swift-audio-io` dependency to the implementation version.
2. Delete `SystemAudioRecordingServicing`, `UnavailableSystemAudioRecorder`, and
   `MacOSSystemAudioRecorder`.
3. Keep `RecordingCaptureSource` as Recorder UI state, but map it into
   `RecordingConfiguration.input`.
4. Collapse `RecordingService` start flow so both microphone and system audio
   call `engine.startRecordingWithReconciliation` or a single package-level
   start path.
5. Attach live waveform receivers to `engine` for both sources.
6. Collapse stop flow so both sources call `engine.stopRecording()` and then
   persist the returned URL.
7. Keep Recorder-specific behavior unchanged: source picker, disabled
   segmentation for system audio if desired, user-facing error copy, persistence,
   Live Activity, location metadata, and app privacy strings.

Recommended Recorder validation:

```sh
xcodegen generate
xcrun swift test --package-path Packages/AppLibrary
xcodebuild -workspace Recorder.xcworkspace -scheme Recorder -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
git diff --check
```

## Phased implementation checklist

### Phase 0 - SDK and behavior spike

- [x] Verify the local Xcode Core Audio process-tap APIs used by Recorder:
  `CATapDescription`, `AudioHardwareCreateProcessTap`,
  `AudioHardwareAggregateDevice`, and `AudioDeviceCreateIOProcIDWithBlock`.
- [x] Classify startup retry behavior from SDK error constants and Recorder's
  current Core Audio path.
- [ ] Build a small throwaway harness or package test seam that can start and
  stop a process tap.
- [ ] Confirm source format and channel layout from `kAudioTapPropertyFormat`,
  and log raw `inInputTime` from a real recording to confirm `mHostTime` is the
  `mach_absolute_time` domain and which validity flags are set.
- [ ] Discover the aggregate device IO buffer size
  (`kAudioDevicePropertyBufferFrameSize`, `kAudioDevicePropertyUsesVariableBufferFrameSizes`)
  and confirm whether it is fixed or variable, to size the handoff + converted
  buffers.
- [ ] Validate IOProc realtime safety: instrument the harness to confirm the
  IOProc path performs no allocation and the lock-free `SPSCRingBuffer` handoff
  holds under load (no blocking, drop-on-full behaves).
- [ ] Design the package-internal `AudioHardware*` wrapper layer
  (`CoreAudioProcessTapSession` + tap/aggregate/device wrappers) — these are
  net-new, not a copy; decide ownership and visibility.
- [ ] Design the public process-discovery API
  (`SystemAudioProcessObjectID` translation + `SystemAudioProcessCatalog`) and
  where it lives relative to `PlatformAudioBackend`.
- [ ] Confirm permission behavior with `NSAudioCaptureUsageDescription`.
- [ ] Decide the fake-backend seam for deterministic tests (must allow injecting
  synthetic source buffers + `AudioTimeStamp`s through the pump into
  `processAudio`).

### Phase 1 - Public configuration surface

- [ ] Land the `RecordingConfiguration` refactor as a **standalone PR first**:
  replace stored `inputConfiguration` + top-level `tapInterval` with
  `input: RecordingInput`, add the source-agnostic `format` accessor, and
  rewire all ~10 derived members + `RecordingEngineRuntime` call sites. Fix
  `updateRecordingTapInterval` (pattern-match `.microphone`; no-op for
  `.systemAudio`). Gate the PR on the full microphone test suite.
- [ ] Add `RecordingInput` and `MicrophoneRecordingInput`.
- [ ] Add macOS-only `SystemAudioRecordingInput` (incl. `excludesCurrentProcess`,
  `tapName`, `aggregateDeviceUIDPrefix`).
- [ ] Add macOS-only `SystemAudioProcessSelection` and `SystemAudioProcessObjectID`.
- [ ] Add the public process-discovery API: `SystemAudioProcessObjectID.currentProcess`
  / `init?(processID:)`, `SystemAudioProcess`, `SystemAudioProcessCatalog`.
- [ ] Add migration conveniences (`.microphone(format:tapInterval:)`,
  `.systemAudio(format:processSelection:)`), but keep the stored model
  source-specific.
- [ ] Add error cases (`captureSourceUnavailable`, `captureSourceFailed`,
  `coreAudioFailed`) and the production OSStatus→`RecordingError` classifier; wire
  retryable statuses through `.session(.notReady)` so `isTransient` drives retry.
- [ ] Promote the reconciliation start API to public (drop `@_spi(Advanced)` from
  the methods, `RecordingDriving`, and the `Exports.swift` re-export line).
- [ ] Update `AudioIO` exports and public API snapshot tests (enumerated list
  above, with `#if os(macOS)` gating).
- [ ] Update README/DocC only enough to document the new source option, process
  selection/discovery, the now-public retry start path, and the host-app
  `NSAudioCaptureUsageDescription` requirement.

### Phase 2 - Runtime refactor with microphone parity

- [ ] Extract common recording setup from microphone tap setup.
- [ ] Introduce internal active-backend state (`activeBackend` in `RecordingState`).
- [ ] Move the microphone tap-removal + engine stop/reset out of `hardStop()` /
  `gracefulStop()` and behind the microphone backend's `stop()`/`cleanup()`, so
  all lifecycle methods dispatch on `activeBackend`.
- [ ] Confirm common code owns the converter artifacts; backends vend only
  `sourceFormat`.
- [ ] Keep microphone behavior byte-for-byte equivalent where possible.
- [ ] Ensure existing microphone tests pass before adding system audio.

### Phase 3 - Core Audio backend

- [ ] Author the package-internal `AudioHardware*` wrappers + `CoreAudioProcessTapSession`
  (net-new code, not a copy).
- [ ] Read + validate the tap source ASBD and discover `maxIOFrames` before
  starting IO; fail terminally on mismatch/unqueryable before `recordingStarted`.
- [ ] Implement the realtime-safe handoff: pre-allocated lock-free
  `SPSCRingBuffer` (byte ring + timing-packet ring); IOProc does memcpy +
  timestamp capture only (no malloc / dispatch / converter / receiver / file).
- [ ] Implement the non-realtime source pump that rebuilds the source-format
  buffer, wraps the `AudioTimeStamp` via `AVAudioTime`, and calls the existing
  `processAudio(buffer:time:to:)` — no `processAudio` signature change.
- [ ] Implement robust partial-start cleanup (best-effort, non-throwing, ordered).
- [ ] Implement OSStatus→`RecordingError` mapping + the retry classifier.
- [ ] Implement the public process-discovery API.
- [ ] Add fake backend tests for lifecycle, sample flow, timing injection, and
  the IOProc no-allocation guarantee.

### Phase 4 - Lifecycle, rotation, and timing hardening

- [ ] Wire system audio into `startRecording` (incl. mono/stereo channel
  validation and ASBD validation before `recordingStarted`).
- [ ] Wire backend dispatch into `stopRecording`, `hardStop`, `gracefulStop`,
  `cleanUp`, and the `warm()` failure path (dispatch on `activeBackend`).
- [ ] Validate and test `rotateRecordingFile` (backend/pump untouched by rotation).
- [ ] Validate and test `recordingTimingSnapshot` for system audio (host time +
  source sample time threaded from the IOProc).
- [ ] Decide and document route/device-change behavior.

### Phase 5 - Demo and Recorder adoption

- [ ] Add a real system-audio mode to `Examples/AudioIODemo`.
- [ ] Document demo permission requirements and expected macOS Settings entry.
- [ ] Point Recorder at the new AudioIO implementation.
- [ ] Remove app-local system-audio recorder code.
- [ ] Simplify Recorder start, receiver attachment, and stop branches.
- [ ] Run Recorder package tests and macOS app build.
- [ ] Perform a real system-audio recording smoke test.

## Resolved decisions

- `.systemAudio` is public from the first implementation, not hidden behind SPI.
- Process include/exclude filters are public in the first implementation and
  covered by tests.
- System audio participates in reconciliation retry for bounded startup
  not-ready failures only. Permission, stale object, unsupported operation,
  unsupported format, configuration, filesystem, and unknown failures are
  terminal.
- Recording configuration becomes source-specific, even though this is a
  breaking change. `tapInterval` moves under microphone input configuration
  instead of remaining a top-level value.
- `Examples/AudioIODemo` should expose system audio after the feature lands.
- **Process selection is object-ID-first with a public discovery API.** Ship
  `SystemAudioProcessObjectID` translation (`currentProcess` / `init?(processID:)`)
  and `SystemAudioProcessCatalog.capturableProcesses()` so callers can resolve
  and enumerate processes; bundle identifiers remain a first-class selector.
- **`tapName` and `aggregateDeviceUIDPrefix` stay public/configurable** with
  documented semantics (the UID prefix is namespaced by an internally appended
  UUID suffix), defaulted via factories.
- **The reconciliation start API is promoted to public** (`startRecordingWithReconciliation`
  / `setDesiredRecordingState`), since Core Audio startup is more brittle than
  microphone and benefits from bounded not-ready retry without reaching for SPI.
- **The IOProc is a pure lock-free copy.** It memcpys the payload + `inInputTime`
  timestamps into pre-allocated `SPSCRingBuffer`s and does nothing else; a
  non-realtime source pump rebuilds the source-format buffer and calls the
  existing `processAudio`, so conversion/writer/receiver/timing are byte-identical
  to microphone capture. No `AVAudioConverter`, `malloc`, `DispatchQueue.async`,
  locks, file I/O, or receiver calls on the realtime thread.
- **Self-exclusion is explicit** via `SystemAudioRecordingInput.excludesCurrentProcess`
  (default `true`), with a bundle-ID fallback when the object-ID lookup fails.
- **Retryable HAL statuses map to `.session(.notReady)`** so the existing
  `RecordingError.isTransient` gate is the single source of truth for the
  reconciliation retry decision; terminal failures use the new error cases.

## Success criteria

- A non-Recorder macOS app can record system audio with `AIOEngine` and a
  `RecordingConfiguration`.
- Recorder no longer carries an app-local Core Audio recorder.
- Microphone recording remains behaviorally unchanged.
- System audio uses the same AudioIO events, writer drain, buffer receiver, file
  rotation, and timing surfaces as microphone recording.
- The implementation contains no Recorder product assumptions.
- Realtime Core Audio callbacks remain bounded and do not perform file I/O,
  Swift concurrency work, or app receiver calls.
