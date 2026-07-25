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

``AIOEngine/startRecording(configuration:)`` returns the destination URL once
the engine is producing output. It performs bounded retry for transient
audio-session and capture-source readiness failures. The deadline defaults to
two seconds and can be configured when creating the engine:

```swift
let engine = AIOEngine(recordingStartTimeout: .seconds(5))
```

Cancel the task awaiting `startRecording` to withdraw startup intent. A second
start while one is pending throws ``RecordingError/startInProgress``; a start
while capture is active throws ``RecordingError/alreadyRecording``.
``AIOEngine/stopRecording()`` returns the final saved URL.

## Segmented recording

``AIOEngine/rotateRecordingFile()`` closes the current file and continues capture into a new file without reinstalling the tap. The closed file appears in the events stream as a `.recordingStarted(url:, format:)` for the *new* URL; the previous file is fully drained before the rotation returns.

## Observing lifecycle

Subscribe to ``AIOEngine/events`` for every recording lifecycle transition:

| Event | When |
|---|---|
| ``AudioIOEvent/recordingStarted(url:format:)`` | Initial start or segment rotation. |
| ``AudioIOEvent/recordingCompleted`` | User-initiated stop completed cleanly. |
| ``AudioIOEvent/recordingFailed`` | Engine-side failure stopped recording. |
| ``AudioIOEvent/recordingInterruption(_:)`` | Route change continuation, or an interruption-driven stop. |
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
- ``AIOEngine/isRecording``

### Errors

- ``RecordingError``
- <doc:ErrorHandling>
