# Recording

Configure inputs and outputs, drive the engine, and observe lifecycle events.

## Configuration

Recording is configured by ``RecordingConfiguration``: a capture source, an
output encoding, and a destination.

### Capture sources

``RecordingConfiguration/input`` is a ``RecordingInput`` — the capture source and
its source-specific options:

- ``MicrophoneRecordingInput`` — the `AVAudioEngine` input tap (iOS and macOS).
  Owns the `tapInterval`.
- `SystemAudioRecordingInput` — a macOS Core Audio process tap that records what
  other apps are playing. See <doc:SystemAudioCapture>.

Each input carries an ``InputConfiguration`` (its ``SampleRate`` and
``ChannelCount``), which you read source-agnostically via
``RecordingConfiguration/format``. For microphone recording you can use the
convenience initializer
``RecordingConfiguration/init(inputConfiguration:outputConfiguration:tapInterval:outputDestination:)``,
which builds a ``MicrophoneRecordingInput`` for you.

### Output

- ``OutputConfiguration`` chooses the ``FileFormat``, ``BitDepth``, and ``EncodingQuality``.
- `outputDestination` selects a temporary file, a directory, or an explicit file URL.

The engine enforces the declared channel matrix:

| Source / format | Max channels |
|---|---|
| AAC, ADTS | 8 (AAC channel layouts) |
| FLAC | 8 |
| WAV, CAF, AIFF | 32 (PCM) |
| System audio (any format) | 2 (mono / stereo mixdown) |

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

For fire-and-forget semantics with background retry on transient startup failures (notably Core Audio system-audio bring-up), use the reconciliation entry points:

```swift
import AudioIO

engine.setDesiredRecordingState(true, configuration: configuration)
```

These complement the canonical ``AIOEngine/startRecording(configuration:)``: they keep retrying while the desired state stays `true` until the engine warms, the timeout elapses, or a non-transient ``RecordingError`` surfaces. Read ``AIOEngine/consumeLastRecordingStartFailure()`` to recover the failure behind a fire-and-forget start. See ``AIOEngine/setDesiredRecordingState(_:configuration:)`` and ``AIOEngine/startRecordingWithReconciliation(configuration:)``.

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
- ``RecordingInput``
- ``MicrophoneRecordingInput``
- ``InputConfiguration``
- ``OutputConfiguration``
- ``SampleRate``
- ``ChannelCount``
- ``FileFormat``
- ``BitDepth``
- ``EncodingQuality``

### System audio (macOS)

- <doc:SystemAudioCapture>
- ``SystemAudioRecordingInput``
- ``SystemAudioProcessSelection``
- ``SystemAudioProcessCatalog``
- ``SystemAudioProcess``
- ``SystemAudioProcessObjectID``

### Engine surface

- ``AIOEngine/startRecording(configuration:)``
- ``AIOEngine/stopRecording()``
- ``AIOEngine/rotateRecordingFile()``
- ``AIOEngine/startRecordingWithReconciliation(configuration:)``
- ``AIOEngine/setDesiredRecordingState(_:configuration:)``
- ``AIOEngine/consumeLastRecordingStartFailure()``
- ``AIOEngine/isRecording``

### Errors

- ``RecordingError``
- <doc:ErrorHandling>
