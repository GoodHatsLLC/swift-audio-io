# Changelog

All notable changes to AudioIO are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com) categories, and
releases follow the versioning policy in `README.md` and `ROADMAP.md`.

## Unreleased

### Removed

- **Source-breaking.** `VerboseError`. It was never constructed anywhere in the
  package, and mapped `AVAudioSession`, AudioFile, AudioCodec, AUGraph,
  AudioUnit — and MIDI — status codes into a description string that nothing
  read.
- **Source-breaking.** `VisualizationSink` and
  `AudioVisualizationEngine.subscribe(request:sink:)`. The protocol had no
  conformers and the sink-based overload had no callers; it was a thin wrapper
  over `subscribe(request:handler:)`, which remains.
- `AIOEngine.sessionConfiguration`, a public forward to
  `recordingSessionConfiguration` with no callers. Use
  `recordingSessionConfiguration` directly.
- `IOSPlatformAudioBackend`. It was unreachable — the only call to
  `PlatformAudioBackendFactory.makeDefault()` is inside `#if os(macOS)`. Its
  capabilities are already covered by `AudioEnvironment.notifications` and
  `AudioRouteObserver`, which carry the route-change reason and previous route
  that `PlatformAudioRouteEvent` cannot express.
- `AudioEnvironmentManager._InputConfigError`, which was unreferenced.

## 0.10.3 - 2026-07-24

### Removed

- **Source-breaking.** The `extension Reporter where E == any Error` overloads of
  `callAsFunction`. With `E == any Error`, `throws(E)` is spelled `throws`, so
  after substituting the constraint those overloads had signatures identical to
  the generic ones and could only be ranked against them by
  `@_disfavoredOverload`, which both sides carried. Swift 6.4 (Xcode 27 beta 4)
  no longer breaks that tie via constrained-extension specialization, so every
  call through `ErrorManaging.reporter(...)` — which always vends
  `Reporter<any Error>` — failed with `ambiguous use of 'callAsFunction'`. The
  generic overloads already cover `E == any Error`.

### Changed

- `Reporter<any Error>` rethrows the original error rather than flattening it
  into `ReportedError.error(description:)`, and propagates `CancellationError`
  as itself rather than as `ReportedError.cancelled`. Error reporting to
  receivers is unchanged, as is the `Reporter<E>` behaviour for every other `E`.
  Callers that only test for failure (`try?`) are unaffected; callers that
  matched on `ReportedError` must match the underlying error instead.
  `ReportedError` is otherwise unchanged and still usable as
  `Reporter<ReportedError>`.

## 0.10.1 - 2026-07-24

### Fixed

- `AIORecording` compiles under Swift 6.4 (Xcode 27 beta 4). The recording
  publish hop passed a typed-throws closure to `MainActor.run`, which crashed the
  frontend during IR emission (`constructing SILType with type that should have
  been eliminated by SIL lowering`) and made the whole package unbuildable. The
  hop now returns `Result<URL, RecordingError>` and the caller unwraps it with
  `Result.get()`, which is itself `throws(Failure)` — the thrown error type is
  unchanged and no behaviour changed.
- `AIOTests/PublicAPISnapshot` no longer fails to compile on ambiguity between
  `AudioIO.SourceLocation` and swift-testing's `SourceLocation`; the snapshot now
  names the `AudioIO` type explicitly.

## 0.10.0 - 2026-07-24

### Added

- `AIOEngine.startRecording(configuration:)` now performs bounded readiness
  retry for every capture source and reports timeout, cancellation, and
  competing starts as typed `RecordingError` cases.
- `AIOEngine` accepts an immutable `AudioSessionAuthority` and recording-start
  timeout at initialization.
- Added the platform-neutral `AudioSystemEvent`, `AudioRouteChange`, and route
  snapshot values.

### Changed

- Recording intent belongs to the caller: retaining or cancelling the task
  awaiting `startRecording` is the complete startup lifecycle.
- Startup failures throw from `startRecording`; `recordingFailed` is reserved
  for failures after capture has begun.
- Microphone and system-audio capture now share one internal source-lifecycle
  seam for start, graceful or immediate stop, and cleanup.
- Recording state and operations now have one internal `RecordingLifecycle`
  owner with focused capture, writer, receiver, and rotation helpers; the
  consumer-facing `AIOEngine` recording API is unchanged.
- `AudioEnvironmentManager` now emits one audio-system event surface, and
  `AIOEngine.handleAudioSystemEvent(_:)` applies shared recording and playback
  recovery policy on both platforms.

### Removed

- Removed the desired-state/reconciliation APIs, public partial `warm` surface,
  mutable audio-session delegate wiring, and `reconciliationFailed` event.
- Removed the platform-specific engine interruption handlers, AVFoundation
  interruption aliases, and four separate environment event subscriptions.

## 0.9.0 - 2026-07-21

### Added

- `AsyncBroadcaster.subscribe()` synchronously registers an explicitly
  cancellable subscription so lifetime-owned consumers cannot miss events while
  their processing task is waiting to be scheduled.
- Audio route, port, and session snapshots can be constructed from captured
  values, allowing route-change behavior to be replayed and tested without
  consulting the process-global audio session.

### Changed

- Recording measurement mode is now owned and persisted by each
  `AudioEnvironmentManager`. `AudioSessionConfiguration` is a pure value factory,
  and the recording engine derives the active mode through its injected audio
  session delegate instead of reading or mutating global preferences.
- File and output configuration helpers use owned `FileManager` and
  `UserDefaults` instances, and shared formatter state has been removed.

## 0.8.1 - 2026-07-20

### Fixed

- iOS microphone activation now awaits persisted input/channel restoration, and
  stereo selection explicitly requests two input channels before publishing its
  state. Recording bring-up rejects and retries a route or input tap that exposes
  fewer channels than requested instead of silently producing duplicated mono in
  a stereo processing format.

## 0.8.0 - 2026-07-17

### Added

- `RecordingTimingSnapshot` now reports the last persisted-buffer host time,
  exact persisted frame count, and exact frame count spanning the measured host
  interval. Multi-device clients can use the interval to measure effective
  capture rate without estimating from file duration or counting dropped tap
  callbacks.

## 0.7.0 - 2026-07-16

### Changed

- Audio-session activation and deactivation now use async AudioIO APIs and run
  the blocking iOS `AVAudioSession.setActive` operation on AudioIO's serialized
  off-main session queue. `AudioEnvironmentManager.setAudioSessionActive`,
  `AudioSessionDelegate.setAudioSessionActive`, and `AIOEngine.warm` are now
  async so callers can suspend without blocking the main thread.

## 0.6.0 - 2026-07-14

### Added

- Added `AudioChannelConfigurationAvailability` and
  `AudioEnvironmentConfiguring.channelConfigurationAvailability` so clients can
  distinguish an unresolved input from a fixed mono/stereo input or an input
  whose channel configuration is user-selectable. The capability follows the
  system-default input without pinning it as a preferred device.

## 0.5.4 - 2026-07-08

### Fixed

- macOS: an input-route change (device added/removed, default input changed)
  during a system-audio recording no longer reinstalls the AVAudioEngine input
  tap. Previously the route-change handler treated every active recording as a
  microphone recording: it started the microphone and overwrote the shared tap
  converter, so the system-audio file silently captured microphone audio (or
  went silent). `reinstallTap` now also refuses system-audio configurations
  outright.
- macOS: `AudioEnvironmentManager` no longer pins a concrete input device when
  the selection is "system default" (`selectedInput == nil`). Refreshes keep
  `nil` selections so recordings follow default-input changes, a disappeared
  explicit selection falls back to the system default instead of an arbitrary
  remaining device, and the explicit selection re-attaches when its device
  returns.

### Added

- macOS: a diagnostic warning is logged when system-audio self-exclusion cannot
  resolve the host's HAL process object and falls back to bundle-identifier
  exclusion.

## 0.4.0 - 2026-07-03

### Added

- Added `PlaybackScrubMode` and `AIOEngine.scrub(to:mode:)` so callers can
  express interactive drag scrubs separately from committed seeks without
  reaching for playback-polling internals.

## 0.1.1 - 2026-05-28

### Fixed

- Paused playback now reports the current position instead of resetting
  `AIOEngine.Playback.time` to the segment start frame. While an
  `AVAudioPlayerNode` is paused it cannot report `lastRenderTime`, so
  `getPlayback(for:)` previously fell back to the start frame on every poll;
  it now returns the last observed position for the active playback instance.
  Consumers driving a playhead from `Playback.time` no longer see it jump to
  the start of the track on pause.

## 0.1.0 - 2026-05-28

Initial public release. This is the start of the
`0.x` line — the public API may change between minor versions until `1.0.0`.

### Added

- **`AudioIO`** umbrella product: recording, playback, audio-session coordination,
  real-time visualization, and microphone-health monitoring, driven through a single
  `AIOEngine`.
- **`AudioSignals`** product: signal-domain data types (`TimeDomainData`,
  `FrequencyDomainData`, `BeatInfo`) and multi-band LOD waveform extraction
  (`MultiBandLODProcessor`, `OfflineLODExtractor`), usable without the recording stack.
- **`Tools`** product: async/concurrency primitives (`AsyncBroadcaster`, `Subject`,
  `SPSCRingBuffer`) surfaced because they appear in AudioIO's public contracts.
- Unified `AIOEngine.events: AsyncBroadcaster<AudioIOEvent>` stream carrying every
  engine-level error and recording/playback lifecycle transition.
- Per-domain typed errors (`RecordingError`, `PlaybackError`, `SessionError`) under
  the `AudioIOError` marker protocol.
- Canonical `startRecording(configuration:) async throws(RecordingError) -> URL`
  entry point; reconciliation-mode recording behind `@_spi(Advanced)`.
- DocC catalog with externally-focused topics (Getting Started, Platform Matrix,
  Threading Model, Error Handling, Events) and per-surface reference docs.
- `Examples/AudioIODemo`: a minimum-viable iOS + macOS sample app.
- Apache-2.0 license.

### Platforms

- iOS 26+, macOS 26+. Swift 6.2 with strict concurrency.
