# Recording

Configure inputs and outputs, drive the engine, and observe lifecycle events.

## Configuration

Recording is configured by ``RecordingConfiguration``:

- ``InputConfiguration`` chooses the ``SampleRate`` and ``ChannelCount``.
- ``OutputConfiguration`` chooses the ``FileFormat``, ``BitDepth``, and ``EncodingQuality``.
- `outputDestination` selects a temporary file, a directory, or an explicit file URL.

The engine enforces the declared channel matrix:

| Format | Max channels |
|---|---|
| AAC, ADTS | 8 (AAC channel layouts) |
| FLAC | 8 |
| WAV, CAF, AIFF | 32 (PCM) |

Unsupported channel counts fail with ``RecordingError/unsupportedChannelCount(requested:maximum:)`` before the engine installs a recording tap.

## Driving the engine

The canonical entry point is single-shot and typed-throws:

```swift
let url = try await engine.startRecording(configuration: configuration)
// …record for some duration…
let savedURL = try await engine.stopRecording()
```

``AIOEngine/startRecording(configuration:)`` returns the destination URL as soon as the engine produces output. ``AIOEngine/stopRecording()`` returns the final saved URL.

### Fire-and-forget reconciliation

For fire-and-forget semantics with background retry on transient session failures, opt into the `@_spi(Advanced)` reconciliation entry points:

```swift
@_spi(Advanced) import AudioIO

engine.setDesiredRecordingState(true, configuration: configuration)
```

These are part of the SPI tier and not covered by SemVer — they exist for power users who accept tighter coupling. See ``AIOEngine/setDesiredRecordingState(_:configuration:)`` and ``AIOEngine/startRecordingWithReconciliation(configuration:)``.

## Segmented recording

``AIOEngine/rotateRecordingFile()`` closes the current file and continues capture into a new file without reinstalling the tap. The closed file appears in the events stream as a `.recordingStarted(url:, format:)` for the *new* URL; the previous file is fully drained before the rotation returns.

## Observing lifecycle

Subscribe to ``AIOEngine/events`` for every recording lifecycle transition:

| Event | When |
|---|---|
| ``AudioIOEvent/recordingStarted(url:format:)`` | Initial start or segment rotation. |
| ``AudioIOEvent/recordingCompleted`` | User-initiated stop completed cleanly. |
| ``AudioIOEvent/recordingFailed`` | Engine-side failure stopped recording. |
| ``AudioIOEvent/recordingInterruption(_:)`` | Route change, graceful stop, or interruption. |
| ``AudioIOEvent/error(_:)`` | Tap-thread or drain failure surfaced asynchronously. |

See <doc:Events> for the full subscription pattern.

## Topics

### Configuration

- ``RecordingConfiguration``
- ``InputConfiguration``
- ``OutputConfiguration``
- ``SampleRate``
- ``ChannelCount``
- ``FileFormat``
- ``BitDepth``
- ``EncodingQuality``

### Engine surface

- ``AIOEngine/startRecording(configuration:)``
- ``AIOEngine/stopRecording()``
- ``AIOEngine/rotateRecordingFile()``
- ``AIOEngine/isRecording``

### Errors

- ``RecordingError``
- <doc:ErrorHandling>
