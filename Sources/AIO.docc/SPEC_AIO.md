# SPEC — AIO (Tools, AIOEngine)

**Scope**: `Packages/AIO/` as a reusable audio + utilities library, with a particular focus on the `AIOEngine` module.  
**Primary consumers**: Recorder‽ app + extensions (via AppLibrary), and any future apps that need the same “robust capture/playback” behavior.

This document specifies:

- what the AIO package provides (module-by-module),
- the public contracts and invariants of `AIOEngine`,
- the intended concurrency and error-reporting model,
- how audio-session ownership is split between “environment management” and “engine operations”,
- major tradeoffs and footguns.

---

## 1. Package Overview

**Swift Package**: `Packages/AIO/Package.swift`  
**Products**:

- `Tools` (library)
- `AIOEngine` (library)

The package is intentionally split so that non-audio infrastructure can be reused without pulling in AVFoundation-heavy code.

### 1.1 Design goals

- **Robust recording startup** in real-world lifecycle conditions (cold launch, background wake, route changes).
- **Avoid “surprise microphone use”** by separating *session category configuration* from *session activation*.
- **Strict concurrency compatibility** (Swift 6.2, strict concurrency), without forcing consumers to reason about AVFoundation threading details everywhere.
- **Simple integration surface** for app-layer orchestration: one engine for capture/playback plus a few managers for device/session configuration.
- **Explicit error surfacing**: capture failures should be diagnosable (logs + structured errors), and user-facing error presentation should be owned by the app layer.

---

## 2. Modules

### 2.1 `Tools`

**Purpose**: foundational utilities and concurrency primitives used across AIO and upstream app packages.

Key building blocks (non-exhaustive):

- **Concurrency & async utilities**
  - `AsyncBroadcaster`, `Subject`, `AsyncStream` helpers
  - `Synchronized`, `Mut` (lock-backed state helpers)
  - `WithTimeout`, `WithCancellationOperation`, `OnCancellation`
- **Audio-adjacent plumbing**
  - `RingBuffer` (used by `AIOEngine` for buffering tap output before writing/visualizing)
  - `BufferReceiver` protocol (push-style stream of audio buffers for visualization / metering / ML)
- **Diagnostics / safety**
  - `ErrorContext` (wrap underlying errors for consistent logging)
  - typed-throws helpers (e.g. `TypedThrowsError`) for Swift 6 mode

**Contract**: `Tools` types must be safe to depend on from app and extension targets (no UI coupling).

### 2.2 `AIOEngine`

**Purpose**: the audio I/O library:

- capture (recording) with robust startup and resilience to route changes,
- playback (full file + segment playback + scrubbing),
- input/output preference handling (sample rate, channel count, input device/source),
- app-friendly error and event streams.

`AIOEngine` is the “hot path” module: it depends on AVFoundation/AVFAudio and owns performance-sensitive work.

---

## 3. High-Level Architecture (AIOEngine)

The `AIOEngine` module intentionally separates:

1. **Audio environment management** (what devices exist? what is the preferred input/source? what sample rate? what session category/options?)  
   → `AudioEnvironment`, `AudioEnvironmentManager`, `OutputConfigurationManager`, and related types.

2. **Engine operations** (start/stop capture, write to file, play audio, handle route changes)  
   → `AIOEngine` itself.

This split enables “configure early, activate late”:

- `AudioEnvironmentManager` configures the shared `AVAudioSession` category/options *without activating* the session.
- `AIOEngine` activates the session *only when it is about to record/play* and configures per-recording preferences.

---

## 4. Concurrency Model

### 4.1 Actors and isolation

- `AIOEngine` is `@Observable` and `Sendable`, but its **stateful API is primarily `@MainActor`**.
  - UI and app-layer orchestration can bind to `@Observable` properties (`isRecording`, `playback`, etc.) safely.
  - Audio callbacks and file-writing run off-main as needed.
- Internals use a mix of:
  - `@MainActor` state and lifecycle coordination,
  - **nonisolated AVFoundation objects** (`AVAudioEngine`, `AVAudioPlayerNode`) with guarded access,
  - explicit synchronization (`Synchronized`, `Mut`) for shared internal state.

### 4.2 Background work

`AIOEngine` uses detached tasks for:

- the **writer loop** that flushes buffered audio into the output file,
- periodic playback state sampling (timer loop) for UI updates.

**Contract**: app code should not assume file writing occurs synchronously with recording start/stop.

### 4.3 Typed throws

Where practical, AIO uses typed throws (e.g. `throws(AIOError)` / `throws(ManagerError)`) to keep error handling explicit under strict concurrency and Swift 6 mode.

---

## 5. Core Types and Contracts (AIO Package)

The public `AIOEngine` product now re-exports the internal `AIOAudioSession`, `AIOEngineCore`,
`AIORecording`, `AIOPlayback`, and `AIOVisualization` targets. The source-of-truth files below use
their current post-refactor locations.

### 5.1 `RecordingConfiguration`

**File**: `Packages/AIO/Sources/AIOAudioSession/Env/RecordingConfiguration.swift`

`RecordingConfiguration` is the single “recording recipe” value used to:

- choose input settings (`InputConfiguration`),
- choose output encoding (`OutputConfiguration`),
- define tap cadence (`tapInterval`).

It also provides derived formats:

- `processingFormat`: float32, non-interleaved, sized to the requested sample rate + channel count, for the internal processing pipeline.
- `fileFormat`: format settings for the chosen file type (AAC/ADTS/FLAC/WAV/CAF) including validation.
- `tapConfiguration(...)`: parameters for `AVAudioNode.installTap`.

**Invariants**:

- `fileFormat` may be `nil` if the requested file format is invalid for the given sample rate/channel count.
- `tapConfiguration.bufferSize` must be > 0, otherwise warming fails.

### 5.2 `InputConfiguration`, `SampleRate`, `ChannelCount`

**Files**:

- `Packages/AIO/Sources/AIOAudioSession/Input/InputConfiguration.swift`
- `Packages/AIO/Sources/AIOAudioSession/Input/SampleRate.swift`
- `Packages/AIO/Sources/AIOAudioSession/Input/ChannelCount.swift`

`InputConfiguration` is a lightweight value type: sample rate + channel count.

`SampleRate` exposes “common cases” (e.g. 44.1kHz, 48kHz, 96kHz, 192kHz) but can wrap any `Double`.

`ChannelCount` is a wrapper over `AVAudioChannelCount`, with notable stable cases:

- `.mono` (1)
- `.stereo` (2)

### 5.3 `OutputConfiguration`, `FileFormat`, `BitDepth`, `EncodingQuality`

**Files**:

- `Packages/AIO/Sources/AIOAudioSession/Input/OutputConfiguration.swift`
- `Packages/AIO/Sources/AIOAudioSession/Env/Output/FileFormat.swift`
- `Packages/AIO/Sources/AIOAudioSession/Env/Output/BitDepth.swift`
- `Packages/AIO/Sources/AIOAudioSession/Env/Output/EncodingQuality.swift`

`OutputConfiguration` selects:

- container/codec (`FileFormat`: `caf`, `wav`, `m4a`/`aac`, `adts`, `flac`)
- PCM bit depth for PCM-like formats
- encoding quality for formats that require it (AAC/ADTS)

**Invariants**:

- `OutputConfiguration.isSupported` must be true to be considered valid (bit depth must be in `fileFormat.supportedBitDepths`).
- For formats where `requiresQuality == false`, quality collapses to `.maximum` (meaning “no-op”).

### 5.4 `AIOEngine`

**File**: `Packages/AIO/Sources/AIOEngineCore/AIOEngine.swift`

#### 5.4.1 Public state

- `isRecording` (`@MainActor`): actual capture state.
- `wantsRecording` (`@MainActor`): desired state, used by reconciliation.
- `playback` (`@MainActor`): current playback snapshot (or `nil`).
- `errors`: async broadcaster of errors occurring during engine operation.

#### 5.4.2 Events and callbacks

- `onRecordingStarted(url, formatString)`
- `onRecordingCompleted()`
- `onRecordingFailed()`
- `onRecordingInterruption(RecordingInterruption)`
- `onReconciliationFailed(desiredState)`
- `onSegmentCompleted(url, formatString)` (for segmented recording / file rotation)

**Contract**: callbacks are invoked on `@MainActor` unless explicitly documented otherwise.

#### 5.4.3 Error model (`AIOError`)

`AIOError` includes:

- lifecycle errors (`notRecording`, `alreadyRecording`, `cannotPlayWhileRecording`)
- configuration errors (`invalidRecordingConfiguration`, `audioSessionNotReady`)
- AVFoundation wrappers:
  - `engineStartFailed(error: ErrorContext)`
  - `audioSessionFailed(operation, error: ErrorContext)`
  - `audioFileFailed(operation, url, error: ErrorContext)`

`AIOError.isTransient` is used by reconciliation to decide whether to retry (notably `audioSessionNotReady`).

### 5.5 `AudioEnvironment` and `AudioEnvironmentManager`

**Files**:

- `Packages/AIO/Sources/AIOAudioSession/Env/AudioEnvironment.swift`
- `Packages/AIO/Sources/AIOAudioSession/Env/AudioEnvironmentManager.swift`

`AudioEnvironment` is a small wrapper around `AVAudioSession` providing:

- current input (`AudioInput`) and available inputs,
- current source (`AudioSource`) and available sources,
- current sample rate and sample-rate requests,
- notification streams (interruptions, route changes, media services, etc.).

`AudioEnvironmentManager` is the long-lived, `@MainActor` orchestrator that:

- configures the audio session **category/options early** (without activation),
- monitors notification streams and keeps cached “UI-friendly” mirrors:
  - selected input, sources, sample rate, channel count, orientation,
- exposes `readySignal()` once its subscriptions are established,
- optionally activates/deactivates the session via `setAudioSessionActive(_:)` when the app decides it should “claim” audio resources.

**Readiness contract**:

- `run()` must be started (typically in a long-lived `Task`) to set `isRunning = true` and subscribe to notifications.
- `readySignal()` throws `.notRunning` if `run()` hasn’t started yet; callers that start `run()` asynchronously should tolerate brief races (see “Footguns”).

### 5.6 Error reporting (`ErrorManaging`)

**File**: `Packages/AIO/Sources/AIOAudioSession/Env/ErrorManaging.swift`

`ErrorManaging` is the narrow protocol used by “business logic” code to report errors without depending on SwiftUI/UI types. It supports:

- `enqueue(...)` (main-actor) to store/display an error event,
- `reporter(...)` to create a `Reporter<any Error>` closure for ergonomic `do/catch` reporting.

The concrete `ErrorManager` (also in `Env/`) is UI-consumable and is typically injected via environment at the view layer in the app.

---

## 6. Threading Model (AIOEngine)

### 6.1 Thread Domains

AIOEngine uses five distinct thread domains. Each property and method belongs to exactly one domain:

| Domain | Mechanism | Responsibilities |
|---|---|---|
| **MainActor** | Swift actor isolation | Observable state (`isRecording`, `playback`), lifecycle coordination, AVAudioSession configuration, callbacks |
| **engineControlQueue** | Serial `DispatchQueue` (`.default` QoS) | All `AVAudioEngine` graph mutations: attach, connect, start, stop, prepare, reset, installTap |
| **tapCallback** | AVAudioEngine internal thread | `processAudio()` — format conversion, lock-free writes to SPSC ring buffers |
| **writerQueue** | Serial `DispatchQueue` (`.userInitiated` QoS) | File I/O: draining ring buffers into `AVAudioFile` / `ExtAudioFile` |
| **receiverQueue** | Serial `DispatchQueue` (`.userInitiated` QoS) | Visualization: draining ring buffers and forwarding to `BufferReceiver`s |

### 6.2 Cross-Domain Communication

- **MainActor ↔ engineControlQueue**: Synchronous (`runOnEngineControlQueue`) and asynchronous (`withEngineControlQueue`) dispatch.
- **engineControlQueue → tapCallback**: `TapSnapshot` (lock-free cached copy) updated atomically by the configuration thread; read without locking by the tap thread via `withLockIfAvailable` with stale-cache fallback.
- **tapCallback → writerQueue**: `SPSCRingBuffer<Float>` (lock-free single-producer/single-consumer).
- **tapCallback → receiverQueue**: `SPSCRingBuffer<Float>` + `SPSCRingBuffer<TimingPacket>`.
- **Cross-domain signals**: `ManagedAtomic<Bool/Int/Int64>` for writer control flags, tap error codes, and sample time tracking.

### 6.3 Tap Thread Characterization

AVAudioEngine tap blocks run on an internal `RealtimeMessenger.mServiceQueue` (WWDC 2019, Session 510), **not** the hard-real-time render thread. Only `AVAudioSourceNode` and `AVAudioSinkNode` render blocks run under real-time constraints.

AIO's `processAudio()` uses `withLockIfAvailable` for non-blocking state access with a cached snapshot fallback, avoiding priority inversion on the semi-RT tap thread. In DEBUG builds, a `TapThreadChecker` asserts that `processAudio()` always runs on the same thread.

### 6.4 Runtime Safety Assertions

In DEBUG builds, AIO includes:

- **`TapThreadChecker`**: Detects unexpected thread migration in the tap callback.
- **`dispatchPrecondition`**: Asserts correct queue identity for engine control and writer/receiver queue closures.

---

## 7. Recording Lifecycle (AIOEngine)

### 7.1 Warm → start recording

The primary recording start path is:

1) `warm(configuration:)` (`@MainActor`)  
2) `startRecording(configuration:)` (async, typed-throws)

`warm(configuration:)` performs:

- output file creation in `FileManager.default.temporaryDirectory`,
- input format validation (channel count and sample rate must be > 0),
  - this is **defensive**: installing a tap with an invalid format can raise an uncatchable Objective‑C exception,
- audio session preference configuration + activation (via `configureAudioSession(for:)`),
- ring buffer allocation sized to requested processing format,
- tap installation on the input node,
- caching engine state (file, URL, config, formats, buffers).

`startRecording(configuration:)` then:

- starts the `AVAudioEngine`,
- emits `onRecordingStarted`,
- launches the detached writer task,
- flips `isRecording = true`.

### 7.2 Tap processing and buffering

The audio tap closure calls `processAudio(...)` (nonisolated):

- converts audio into the processing format (`AVAudioConverter`), cached across calls,
- calculates converter output capacity based on the sample-rate ratio (avoids distorted output on resampling),
- enqueues per-channel float samples into ring buffers,
- forwards frames to any attached `BufferReceiver<Float>` receivers.

### 7.3 File writing (writer loop)

The writer loop:

- periodically drains the ring buffers into an `AVAudioPCMBuffer`,
- writes to the `AVAudioFile`,
- stops on cancellation, flushing remaining buffered audio where possible.

**Contract**: file write errors are logged and surfaced; they do not necessarily crash the process.

### 7.4 Stop recording

- `stopRecording()` (`@MainActor`) removes the tap, stops the engine, cancels the writer task and awaits it, closes the file, resets cached formats, and emits `onRecordingCompleted`.
- `hardStop()` exists for failure paths and “configuration changes that require teardown”.

### 7.5 Segmented recording (file rotation)

`rotateRecordingFile()` (`@MainActor`) is used for “segmented recording mode”:

- creates a new output file,
- cancels and awaits the current writer task so the old file can flush,
- swaps state to the new file + URL,
- starts a new writer loop without dropping samples (tap keeps running),
- emits `onRecordingStarted` for the new segment.

---

## 8. Desired-State Reconciliation

### 8.1 Motivation

On iOS/macOS, “start recording now” is often not immediately satisfiable due to:

- audio session still configuring / returning from background,
- route changes (Bluetooth, wired mic insertion/removal),
- media services reset,
- permission gating,
- transient `AVAudioEngine` start failures.

### 8.2 Mechanism

`AIOEngine` exposes:

- `wantsRecording` as a “desired state” flag, and
- `startRecordingWithReconciliation(configuration:)` / `setDesiredRecordingState(_:configuration:)`.

Reconciliation:

- attempts `startRecording(configuration:)`,
- retries transient errors (currently `audioSessionNotReady`) until:
  - success, or
  - `ReconciliationConfiguration.timeout` is exceeded, or
  - a non-transient error occurs.

On failure it resets `wantsRecording` back toward reality and triggers `onReconciliationFailed`.

**Contract**: reconciliation is intentionally bounded in time to avoid stale background triggers unexpectedly starting recording long after the user initiated the action.

---

## 9. Playback

`AIOEngine` supports:

- `play(url:)` for full-file playback,
- `playSegment(url:startTime:endTime:onComplete:)` for non-destructive editing previews,
- scrubbing by rescheduling segments from a new frame position,
- `stopPlayback()` / `scrubPlay(to:)` style operations (see `AIOEngine.swift`).

**Contract**:

- playback is forbidden while recording (`cannotPlayWhileRecording`),
- playback state is sampled on a timer to update the `playback` snapshot without excessive SwiftUI updates.

---

## 10. Route Changes and Interruptions

`AIOEngine` includes explicit handling paths:

- `handleRouteChange(event:)` (while recording)
  - attempts to reconfigure the tap for the new input route,
  - may continue recording with quality changes (sample rate / channels) and emits a `RecordingInterruption` describing “continuing with changed quality”.
  - may stop gracefully if continuation is not possible.
- `handleInterruption(type:options:)` (while recording)
  - stops or continues based on system-provided interruption semantics.

This is designed to reduce “silent partial recordings” and to give the app layer enough information to inform the user when quality changed unexpectedly.

---

## 11. Integration Expectations (Recorder‽)

Although AIO is reusable, Recorder‽ uses it with a specific layering:

- App startup configures session category/options early (without activation) via `AudioSessionPreparation.prepareForAppLaunch()` (AppTarget wrapper around `AudioEnvironmentManager`).
- A long-lived `AudioEnvironmentManager.run()` task establishes subscriptions and becomes “ready”.
- The app’s `RecordingService` decides *when* to activate the session and start/stop `AIOEngine`, including reconciling external triggers into a single orchestration path.

This division:

- keeps AIO focused on audio primitives and resilience,
- keeps user messaging / Live Activities / state transport in app-space.

---

## 12. Tradeoffs and Footguns

### 12.1 Audio session activation is a privacy + UX boundary

Setting category/options early improves reliability (input node is less likely to report 0 channels), but activating the session early can:

- show “microphone in use” affordances unexpectedly,
- prevent other apps from using audio,
- violate user expectations.

Thus: configure early, activate only on explicit record/play intent.

### 12.2 Tap installation can crash if input format is invalid

AVAudioNode tap APIs may throw an Objective‑C exception (not a Swift error) if formats are invalid. `warm(configuration:)` defensively validates:

- `inputFormat.channelCount > 0`
- `inputFormat.sampleRate > 0`

and throws `audioSessionNotReady` instead of proceeding.

### 12.3 Format requests are preferences, not guarantees

- `AVAudioSession.setPreferredSampleRate` and `setPreferredInputNumberOfChannels` can be rejected or partially applied.
- Output encoding settings can be invalid (e.g. certain AAC sample rates / extreme channel counts); `RecordingConfiguration` may produce `nil` formats and fail warming.

### 12.4 Catalyst and platform differences

Some iOS-only session options are rejected on Mac Catalyst; `AudioEnvironmentManager.configureAudioSessionCategory(_:)` uses platform-conditional options to avoid leaving the input node in an unusable state.

### 12.5 Re-entrancy and lifecycle timing

`AudioEnvironmentManager.readySignal()` throws `.notRunning` if `run()` hasn’t yet set `isRunning`. When consumers start `run()` asynchronously (common), callers must tolerate brief “cold launch” races by retrying briefly rather than dropping a request.

### 12.6 Temporary directory is intentional but requires app-layer persistence

`AIOEngine` records into `FileManager.default.temporaryDirectory`. The app layer is responsible for:

- moving the file into durable storage,
- attaching metadata (timestamp, device, project, etc.),
- cleaning up orphaned temp files if needed.

---

## 13. Privacy and Policy Alignment

AIO is designed to support Apple’s privacy expectations around recording:

- **No implicit permission prompts**: AIO expects the app to gate start requests on mic permission status.
- **No “background surprise recording”**: session activation happens only when explicitly requested by app logic.
- **User-visible affordances**: when recording is active, OS-level indicators apply; app-layer integrations (Live Activity, notifications) should reinforce visibility.

This keeps policy concerns centralized at the app layer, while AIO provides the technical primitives needed to execute the user’s explicit request reliably.
