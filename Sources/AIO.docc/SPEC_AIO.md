# AIO Public Engine Spec

`AudioIO` is the public umbrella product for AIO's recording, playback,
audio-session, visualization, and signal-processing APIs.

## Products

- `AudioIO`: primary product for app integration.
- `AudioSignals`: standalone signal-processing and waveform data types.
- `Tools`: public utility types that are intentionally used by AIO contracts, such as
  `AsyncBroadcaster`.

## Import Boundary

Start with:

```swift
import AudioIO
```

The umbrella re-exports the session, recording, playback, visualization, mic-health, and
signal-processing modules needed by the public engine workflow. Do not depend on package
implementation targets unless you have a narrow reason to use `AudioSignals` or `Tools`
directly.

## Recording

Recording is configured by ``RecordingConfiguration``:

- ``InputConfiguration`` chooses ``SampleRate`` and ``ChannelCount``.
- ``OutputConfiguration`` chooses ``FileFormat``, ``BitDepth``, and ``EncodingQuality``.
- `tapInterval` controls the tap buffer cadence.
- `outputDestination` selects a temporary file, directory, or explicit file URL.

The engine supports the declared channel matrix enforced by `FileFormat`:

- AAC and ADTS: up to 8 channels with AAC channel layouts.
- FLAC: up to 8 channels.
- WAV, CAF, and AIFF: up to 32 PCM channels.

Unsupported channel counts fail with a typed ``AIOEngine/AIOError`` before the engine
installs a recording tap.

Primary recording calls:

```swift
let engine = AIOEngine()
let configuration = RecordingConfiguration(
  inputConfiguration: .init(sampleRate: .common(.sr48000), channels: .stereo),
  outputConfiguration: .init(fileFormat: .caf, bitDepth: .pcmFloat32, quality: .maximum)
)

try await engine.startRecording(configuration: configuration)
let fileURL = try await engine.stopRecording()
```

Segmented recording uses ``AIOEngine/rotateRecordingFile()`` to close the current file and
continue capture into a new file without reinstalling the tap.

## Playback

Playback is file-based and MainActor-owned:

```swift
let playback = try await engine.play(url: fileURL)
await engine.stopPlayback()
```

Segment playback keeps its public time coordinate segment-relative:

```swift
_ = try await engine.playSegment(url: fileURL, startTime: 3, endTime: 8)
_ = try engine.scrub(to: 1.5) // 1.5 seconds into the active segment
await engine.stopPlayback()
```

Whole-file playback remains file-relative.

## Visualization

Visualization uses token-scoped buffer receivers plus subscriber demand:

```swift
let visualization = AudioVisualizationEngine()
let receiverToken = await engine.attachBufferReceiver(visualization)

let subscription = visualization.subscribe(
  request: VisualizationRequest(
    work: VisualizationWork(
      lod: LODWork(configuration: .default),
      analysis: AnalysisWork(timeDomain: .realTime)
    ),
    eventMask: [.lodSnapshot, .timeDomain]
  )
) { event in
  // Update UI state or schedule rendering.
}

visualization.startVisualization()

subscription.cancel()
receiverToken.invalidate()
```

`BufferReceiver.processBuffer` runs on the realtime audio path. Implementations must be fast,
non-blocking, and avoid allocation.

## Event Model

`AIOEngine` exposes single-owner MainActor callback properties for lifecycle coordination:

- `onRecordingStarted`
- `onRecordingCompleted`
- `onRecordingFailed`
- `onRecordingInterruption`
- `onSegmentCompleted`
- `onReconciliationFailed`
- `onPlaybackStateChanged`
- `onPlaybackUpdated`

These are assignment-based hooks for the app or composition root. Multi-consumer data paths
use token-scoped subscription APIs instead.

Engine errors are also available through `errors`, an async broadcaster of `Error` values.

## Validation Rules

Public initializers that accept user-controlled values must not trap. Public value types use
one of these patterns:

- A non-throwing initializer that clamps to a safe value.
- A throwing `validating...` initializer that reports a typed validation error.
- A specifically named clamping initializer when preserving exact input would be ambiguous.

`precondition` remains reserved for internal invariants after public validation has already
excluded invalid user input.

## Threading

The high-level public API is MainActor-friendly, but the implementation crosses several
domains:

- MainActor: observable engine state, recording/playback lifecycle, callbacks.
- Engine control queue: AVAudioEngine graph mutation.
- Audio tap thread: realtime buffer capture and receiver fan-out.
- Writer queue: file I/O and drain/rotation.
- Playback timer task: periodic playback snapshot updates.
