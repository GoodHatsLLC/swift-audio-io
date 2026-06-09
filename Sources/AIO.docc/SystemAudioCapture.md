# System Audio Capture

Record the audio other apps are playing, on macOS, through the same `AIOEngine`
recording surface as the microphone.

## Overview

On macOS, ``RecordingInput`` has a `systemAudio` case backed by a Core Audio
*process tap*. System audio is selected per recording — the engine reuses the
same converter, writer, buffer-receiver, file-rotation, and timing pipeline as
microphone capture, so everything you already know about <doc:Recording>,
<doc:Events>, and <doc:Visualization> applies unchanged. Only the
``RecordingConfiguration/input`` differs.

System audio is **macOS only**: `SystemAudioRecordingInput` and the
process-selection / discovery types are `#if os(macOS)`, so a configuration that
compiles on iOS can only select the microphone.

```swift
import AudioIO

// Capture all system audio (excluding this app, to avoid a feedback loop).
let configuration = RecordingConfiguration(
  input: .systemAudio(
    SystemAudioRecordingInput(
      format: InputConfiguration(sampleRate: .dvd, channels: .stereo))),
  outputConfiguration: OutputConfiguration(
    fileFormat: .caf, bitDepth: .pcmFloat32, quality: .maximum))

let url = try await engine.startRecording(configuration: configuration)
// …
let saved = try await engine.stopRecording()
```

## Permission

The host app must declare `NSAudioCaptureUsageDescription` in its `Info.plist`.
The first tap creation triggers the macOS audio-recording permission prompt
(this is the system-audio permission, **not** ScreenCaptureKit and **not** the
microphone permission). AudioIO does not supply the usage-description string —
that is the app's responsibility. See `Examples/AudioIODemo` for a working
configuration and a manual-verification flow.

## Choosing what to capture

`SystemAudioProcessSelection` decides which processes the tap mixes:

- `.exclude` — a **global** tap of all system audio *except* the listed
  processes (the default).
- `.includeOnly` — a mixdown of *only* the listed processes.

Processes are named by audio-object id (``SystemAudioProcessObjectID``) and/or
bundle identifier. Bundle identifiers also support process *restore*
(`restoresProcessesByBundleIdentifier`): the tap re-attaches to a process by
bundle id when it relaunches.

```swift
// Only capture a specific set of apps, by object id.
let selection = SystemAudioProcessSelection(
  mode: .includeOnly,
  processObjectIDs: chosenProcessIDs)

let input = SystemAudioRecordingInput(
  format: InputConfiguration(sampleRate: .dvd, channels: .stereo),
  processSelection: selection)
```

### Discovering processes

Raw audio-object ids are opaque, so AudioIO ships a discovery API:

- ``SystemAudioProcessCatalog/capturableProcesses()`` enumerates the processes
  the HAL currently exposes as audio sources, each with its
  ``SystemAudioProcess/processID``, ``SystemAudioProcess/bundleIdentifier``, and a
  best-effort ``SystemAudioProcess/name``.
- ``SystemAudioProcessObjectID/currentProcess`` and
  ``SystemAudioProcessObjectID/init(processID:)`` translate the host (or any) PID
  to an audio-object id.

```swift
let processes = try SystemAudioProcessCatalog.capturableProcesses()
let safari = processes.first { $0.bundleIdentifier == "com.apple.Safari" }
```

### Excluding the recorder itself

`SystemAudioRecordingInput.excludesCurrentProcess` defaults to `true`, so a
global tap never captures the host app's own output (which would feed back).
The implementation resolves the current process to an audio-object id, and falls
back to the host bundle identifier when that lookup fails. For `.includeOnly`
selections it is a no-op (you are already naming exactly what to capture).

## Format and channels

Global process taps are mono or stereo mixdowns, so `format.channels` must be
mono or stereo — more than two channels fails with
``RecordingError/unsupportedChannelCount(requested:maximum:)`` at start, before
any HAL object is created. The tap delivers samples at the system mix rate;
AudioIO resamples to the requested ``SampleRate`` through the same converter the
microphone path uses. There is no `tapInterval` for system audio — the HAL
chooses the IO buffer size.

## Startup retry

Core Audio bring-up is more brittle than the microphone path, so the
reconciliation start API is public and useful here. Use
``AIOEngine/startRecordingWithReconciliation(configuration:)`` (awaitable) or
``AIOEngine/setDesiredRecordingState(_:configuration:)`` (fire-and-forget) to
retry transient *not-ready* startup failures until the engine warms or a
non-transient error surfaces. Only a narrow set of HAL statuses is treated as
transient; permission, unsupported-format, stale-object, and unknown failures
are terminal. See <doc:ErrorHandling> for the error model.

## Lifecycle and threading

System audio honors the same stop/drain, ``AIOEngine/rotateRecordingFile()``,
and ``AIOEngine/recordingTimingSnapshot()`` semantics as the microphone. The
realtime Core Audio IO callback only performs a bounded, lock-free copy; format
conversion, file writing, and buffer-receiver delivery happen off the realtime
thread, matching the guarantees described in <doc:ThreadingModel>.

## Topics

### Selecting the source

- ``RecordingInput``
- ``RecordingConfiguration``

### System-audio configuration

- ``SystemAudioRecordingInput``
- ``SystemAudioProcessSelection``

### Discovering processes

- ``SystemAudioProcessCatalog``
- ``SystemAudioProcess``
- ``SystemAudioProcessObjectID``

### Retry-capable start

- ``AIOEngine/startRecordingWithReconciliation(configuration:)``
- ``AIOEngine/setDesiredRecordingState(_:configuration:)``
- ``AIOEngine/consumeLastRecordingStartFailure()``

### Related

- <doc:Recording>
- <doc:ErrorHandling>
