# Core Audio system audio capture integration plan

Status: proposed

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
}

public enum RecordingInput: Hashable, Sendable {
  case microphone(MicrophoneRecordingInput)
  #if os(macOS)
    case systemAudio(SystemAudioRecordingInput)
  #endif
}

public struct MicrophoneRecordingInput: Hashable, Sendable {
  public var format: InputConfiguration
  public var tapInterval: Duration
}

#if os(macOS)
public struct SystemAudioRecordingInput: Hashable, Sendable {
  public var format: InputConfiguration
  public var processSelection: SystemAudioProcessSelection
  public var tapName: String
  public var aggregateDeviceUIDPrefix: String
}

public struct SystemAudioProcessSelection: Hashable, Sendable {
  public enum Mode: Hashable, Sendable {
    case includeOnly
    case exclude
  }

  public var mode: Mode
  public var processObjectIDs: [SystemAudioProcessObjectID]
  public var bundleIdentifiers: [String]
  public var restoresProcessesByBundleIdentifier: Bool
}

public struct SystemAudioProcessObjectID: RawRepresentable, Hashable, Sendable {
  public var rawValue: UInt32
}
#endif
```

Notes:

- Keep `InputConfiguration` as the requested processing format inside each
  source-specific input: sample rate and channel count still describe the output
  pipeline.
- On macOS, `.systemAudio` should support mono and stereo initially because
  Recorder already maps system audio to stereo.
- `MicrophoneRecordingInput` owns `tapInterval`; system audio does not expose
  `tapInterval` because HAL IO cadence is not the same concept as an
  `AVAudioEngine` input-node tap interval.
- Preserve migration ergonomics with convenience initializers or static factories
  such as `.microphone(format:tapInterval:)` and
  `.systemAudio(format:processSelection:)`, but make the stored model
  source-specific.
- Host apps still own `NSAudioCaptureUsageDescription` in their app bundle.
  AudioIO should document that requirement, not try to supply it.
- Add all new public symbols to `Sources/AudioIO/Exports.swift` and
  `Tests/AIOTests/PublicAPISnapshot.swift`.

### Process filters

Expose include and exclude process filters in the first public system-audio API
and test them. The local macOS 26.5 SDK confirms that `CATapDescription`
supports:

- process object IDs for include/exclude lists,
- bundle identifiers on macOS 26+,
- process restore by bundle identifier on macOS 26+,
- mono and stereo global taps,
- device UID and stream-specific tap initializers.

The initial public AudioIO surface should cover global include/exclude by
process object ID and bundle identifier. Device UID and stream-specific capture
can stay out of the first API unless manual validation shows it is required for
basic system audio. The implementation should still be shaped so device-specific
capture can be added without another model rewrite.

Test expectations:

- default system audio excludes the current process,
- include-only by process object ID builds an include tap description,
- exclude by process object ID builds an exclusive/global tap description,
- include-only by bundle identifier sets `bundleIDs` and restore behavior,
- exclude by bundle identifier sets `bundleIDs`, `exclusive`, and restore
  behavior,
- mixed process-object and bundle-ID filters produce a deterministic tap
  description or fail validation if the SDK cannot represent the combination.

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
rather than escaping as raw framework errors.

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

- Startup retry applies before `recordingStarted` is emitted.
- After recording has started, Core Audio backend failures should emit the same
  AudioIO error/recording-failed events as microphone tap failures and stop the
  active recording.
- Do not auto-restart a running system-audio recording after a post-start HAL
  failure until manual validation proves that restart is safe and does not
  duplicate or truncate user audio unexpectedly.
- Add a test-only classifier for OSStatus-to-retry decisions and unit-test every
  row above.

## Internal architecture

Introduce an internal source backend boundary in `AIORecording`:

```swift
package protocol RecordingCaptureBackend: Sendable {
  var sourceFormat: AVAudioFormat { get }
  func start() throws(RecordingError)
  func stop() throws(RecordingError)
  func cleanup()
}
```

The exact protocol shape can change during implementation. The important split
is:

- Common recording setup owns output URL resolution, writer creation, ring-buffer
  allocation, receiver timing, event emission, and state bookkeeping.
- Microphone backend owns the existing `AVAudioEngine` input tap install/start.
- System-audio backend owns Core Audio tap, aggregate device, IOProc, and cleanup.

`RecordingState` or `RecordingRuntimeState` will need to track the active source
backend so `stopRecording`, `hardStop`, `gracefulStop`, route-change handling,
and cleanup can stop the right capture source.

## Core Audio backend design

Move the generic machinery from Recorder into `AIORecording`, renamed and
de-Recorderized:

- `CoreAudioProcessTapSession`
- process exclusion helpers
- private aggregate device description
- IOProc creation/start/stop/destruction
- OSStatus mapping helpers
- copied sample chunk representation, if still needed

Implementation rules:

- The IOProc must copy or enqueue only.
- The IOProc must not write files.
- The IOProc must not call Swift concurrency APIs.
- The IOProc must not call app-provided `BufferReceiver` objects.
- Format conversion should happen off the IOProc.
- Cleanup must destroy IOProc, aggregate device, and process tap even after
  partial start failures.

Preferred data path:

1. IOProc receives an `AudioBufferList` plus timing.
2. IOProc copies the buffer payload into a bounded handoff structure or serial
   queue item.
3. Non-realtime processing rebuilds an `AVAudioPCMBuffer` with the tap source
   format.
4. AudioIO calls the existing `processAudio(buffer:time:to:)` path so system
   audio uses the same conversion, ring buffers, writer loop, receiver loop,
   metrics, and timing behavior as microphone capture.

If `AVAudioTime` cannot represent the Core Audio timestamp cleanly, add an
internal timing variant rather than dropping timing entirely. The goal is for
`BufferTiming` and `recordingTimingSnapshot()` to remain meaningful for system
audio whenever the HAL provides host time.

## Lifecycle integration

Start:

- Validate source support for the current platform.
- Stop active playback using the existing recording-start behavior.
- Resolve output URL and writer using the existing helpers.
- Allocate writer and receiver ring buffers.
- Prepare source-specific conversion artifacts.
- Start source backend.
- Start writer and receiver loops.
- Emit `.recordingStarted(url:format:)`.
- Set `isRecording` and `wantsRecording` consistently with the microphone path.

Stop:

- Stop the active capture backend first so no more samples enter the pipeline.
- Drain writer sessions through the existing `gracefulStop` path.
- Validate output existence and size.
- Surface write failures through existing `RecordingError.fileFailed` behavior.
- Emit `.recordingCompleted`.

Rotation:

- Reuse `rotateRecordingFile()` if system-audio samples feed the same audio
  ring buffers.
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
  and macOS-only `SystemAudioRecordingInput`,
  `SystemAudioProcessSelection`, and `SystemAudioProcessObjectID`.
- `RecordingConfiguration` hash/equality/description tests cover microphone and
  explicit system audio source configurations.
- Configuration tests prove `tapInterval` is accepted only through
  `MicrophoneRecordingInput`.
- Process-selection tests cover include-only and exclude modes for process
  object IDs and bundle identifiers.
- Retry-classification tests cover every OSStatus row in the reconciliation
  retry investigation.
- iOS compilation proves `.systemAudio` is unavailable on iOS.
- Fake backend tests cover:
  - start success emits `.recordingStarted`
  - stop success emits `.recordingCompleted`
  - start failure cleans up partial Core Audio objects
  - stop failure maps to `RecordingError`
  - samples flow into writer ring buffers
  - samples flow into attached `BufferReceiver`
  - `recordingTimingSnapshot()` captures host time when provided
  - rotation swaps writers without stopping capture
- Existing microphone tests continue to pass unchanged.

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
- [ ] Confirm source format, channel layout, and timing fields delivered by the
  IOProc.
- [ ] Confirm permission behavior with `NSAudioCaptureUsageDescription`.
- [ ] Decide the fake-backend seam for deterministic tests.

### Phase 1 - Public configuration surface

- [ ] Add `RecordingInput`.
- [ ] Add `MicrophoneRecordingInput`.
- [ ] Add macOS-only `SystemAudioRecordingInput`.
- [ ] Add macOS-only `SystemAudioProcessSelection` and
  `SystemAudioProcessObjectID`.
- [ ] Replace `RecordingConfiguration.inputConfiguration` and top-level
  `tapInterval` with source-specific `RecordingConfiguration.input`.
- [ ] Add migration conveniences where useful, but keep the stored model
  source-specific.
- [ ] Add error cases or error mapping helpers.
- [ ] Update `AudioIO` exports and public API snapshot tests.
- [ ] Update README/DocC only enough to document the new source option and
  host-app permission requirement.

### Phase 2 - Runtime refactor with microphone parity

- [ ] Extract common recording setup from microphone tap setup.
- [ ] Introduce internal active-backend state.
- [ ] Keep microphone behavior byte-for-byte equivalent where possible.
- [ ] Ensure existing microphone tests pass before adding system audio.

### Phase 3 - Core Audio backend

- [ ] Move and de-Recorderize Core Audio tap/session code.
- [ ] Replace direct file writing with handoff into AudioIO's existing buffer
  pipeline.
- [ ] Implement robust partial-start cleanup.
- [ ] Implement OSStatus to `RecordingError` mapping.
- [ ] Add fake backend tests for lifecycle and sample flow.

### Phase 4 - Lifecycle, rotation, and timing hardening

- [ ] Wire system audio into `startRecording`.
- [ ] Wire system audio into `stopRecording`, `hardStop`, and cleanup.
- [ ] Validate and test `rotateRecordingFile`.
- [ ] Validate and test `recordingTimingSnapshot`.
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
