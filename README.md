# AudioIO

A Swift audio I/O engine for iOS and macOS: microphone and (macOS) system-audio recording, playback, level-of-detail visualization data, and microphone-health monitoring. Built on AVFoundation, with Swift 6 strict concurrency and typed throws throughout.

> **Status: pre-1.0.** APIs may change between `0.x` releases. We commit to SemVer starting at `1.0.0`. See [ROADMAP.md](ROADMAP.md).

## Install

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/GoodHatsLLC/swift-audio-io.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "AudioIO", package: "swift-audio-io"),
    ]),
]
```

## Quick example

```swift
import AudioIO

let engine = AIOEngine()

// Configure and start recording.
let configuration = RecordingConfiguration(
    inputConfiguration: InputConfiguration(
        sampleRate: .dvd,           // 48 kHz; or .cd / .hiRes96 / 44_100 literal
        channels: .mono
    ),
    outputConfiguration: OutputConfiguration(
        fileFormat: .caf,
        bitDepth: .pcmFloat32,
        quality: .maximum
    )
)

// startRecording returns the URL the engine is writing to.
let recordingURL = try await engine.startRecording(configuration: configuration)

// Observe engine events as they happen.
for await event in engine.events {
    switch event {
    case .error(let error):
        print("Error: \(error)")
    }
}
```

### System audio (macOS)

On macOS you can record what other apps are playing via a Core Audio process tap — same engine, same events, same files, only the `input` differs:

```swift
// Capture all system audio, excluding this app (avoids a feedback loop).
let configuration = RecordingConfiguration(
    input: .systemAudio(
        SystemAudioRecordingInput(
            format: InputConfiguration(sampleRate: .dvd, channels: .stereo)
        )
    ),
    outputConfiguration: OutputConfiguration(fileFormat: .caf, bitDepth: .pcmFloat32, quality: .maximum)
)
let url = try await engine.startRecording(configuration: configuration)
```

The host app must declare `NSAudioCaptureUsageDescription`; the first capture triggers the macOS audio-recording permission prompt. Discover and target specific processes with `SystemAudioProcessCatalog`. See the DocC article *System Audio Capture* and the demo's System Audio mode.

For a complete recording-and-playback demo with a live waveform — including a macOS system-audio mode for manual verification — see [`Examples/AudioIODemo`](Examples/AudioIODemo).

## Platforms

| Platform | Minimum | Status |
|----------|---------|--------|
| iOS      | 26.0    | Primary |
| macOS    | 26.0    | Primary |
| Swift    | 6.3     | Required |
| Xcode    | 26.0    | Required |

Other Apple platforms (tvOS, watchOS, visionOS) are not currently supported. See [ROADMAP.md](ROADMAP.md).

## What's in the box

- **Recording**: microphone and (macOS) system-audio capture behind one configuration; pluggable output formats (CAF, WAV, AIFF, AAC, ADTS, FLAC), interruption handling, route-change recovery.
- **System audio (macOS)**: Core Audio process-tap capture with include/exclude process selection, a process-discovery API, and self-exclusion to prevent feedback.
- **Playback**: file and segment scheduling, scrubbing, mixer amplitude control.
- **Visualization**: real-time multi-band LOD data for waveform rendering. UI is your problem (see philosophy below).
- **Mic health**: input-level monitoring with configurable thresholds.

## Philosophy

AudioIO is an *engine*, not a UI toolkit. The library deliberately excludes:

- SwiftUI bindings and `@Environment` extensions.
- Combine publishers.
- Waveform views or any other rendering code.

See [NOT_AUDIO_IO.md](NOT_AUDIO_IO.md) for the full list and reasoning. Examples demonstrate how to glue AudioIO to SwiftUI in ~15 lines.

## Documentation

- DocC catalog: hosted at [goodhats.github.io/swift-audio-io](https://goodhats.github.io/swift-audio-io) (post-1.0).
- API surface: every public type is exercised in `Tests/PublicAPISnapshotTests` — that file is the canonical "what's stable" reference until DocC ships.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please read [NOT_AUDIO_IO.md](NOT_AUDIO_IO.md) before opening a feature request.

## License

Apache-2.0. See [LICENSE](LICENSE).

AudioIO is maintained by GoodHats LLC.
