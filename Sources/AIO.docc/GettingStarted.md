# Getting Started

Make a recording, observe playback, and subscribe to engine events in under thirty lines.

## Add the package

```swift
.package(url: "https://github.com/GoodHatsLLC/swift-audio-io", from: "0.1.0"),
```

Add `AudioIO` as a target dependency:

```swift
.product(name: "AudioIO", package: "swift-audio-io"),
```

## Record, play, observe

```swift
import AudioIO

@MainActor
func runRecording() async throws {
  let engine = AIOEngine()

  // Subscribe to engine events before driving the engine so you don't
  // miss the first lifecycle event after start.
  let subscriber = Task { @MainActor in
    for await event in engine.events {
      switch event {
      case .recordingStarted(let url, let format):
        print("started \(url.lastPathComponent) in \(format)")
      case .recordingCompleted:
        print("completed cleanly")
      case .recordingFailed:
        print("engine reported a failure")
      case .error(let error):
        print("engine error: \(error.localizedDescription)")
      default:
        break
      }
    }
  }
  defer { subscriber.cancel() }

  let configuration = RecordingConfiguration(
    inputConfiguration: InputConfiguration(sampleRate: .cd, channels: .mono),
    outputConfiguration: OutputConfiguration(
      fileFormat: .caf,
      bitDepth: .pcmFloat32,
      quality: .maximum,
    ),
  )

  let recordingURL = try await engine.startRecording(configuration: configuration)
  // …record for some duration…
  let savedURL = try await engine.stopRecording()

  _ = try await engine.play(url: savedURL)
  await engine.stopPlayback()
}
```

## Required reading

The five concept topics describe the package's shape and the contracts you'll bump into:

- <doc:PlatformMatrix> — iOS 26+ and macOS 26+, and what's iOS-only.
- <doc:ThreadingModel> — which APIs are `@MainActor`, which are `nonisolated`, and where the realtime callback runs.
- <doc:ErrorHandling> — typed-throws domain errors and the events stream's `.error(_)` case.
- <doc:Events> — the unified ``AudioIOEvent`` lifecycle stream.

When you need depth on a specific API:

- <doc:Recording>
- <doc:Playback>
- <doc:AudioSession>
- <doc:Visualization>

## Topics

### Quick orientation

- <doc:PlatformMatrix>
- <doc:ThreadingModel>
- <doc:ErrorHandling>
- <doc:Events>
