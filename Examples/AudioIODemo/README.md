# AudioIODemo

A minimum-viable sample app for the AudioIO Swift package. One screen, one record button, one waveform, one play button. iOS + macOS from a single SwiftUI codebase.

## What it demonstrates

- **The unified events stream** — `RecorderViewModel.init` subscribes to `engine.events` *before* the caller can drive the engine. This is load-bearing: `AsyncBroadcaster` does not replay events for late subscribers.
- **Typed-throws recording** — `engine.startRecording(configuration:)` and `engine.stopRecording()` as the canonical entry points. No reconciliation-mode SPI, no manual reconciliation timer.
- **Token-scoped buffer receivers** — `engine.attachBufferReceiver(visualization)` attaches the visualization engine to the realtime tap. The returned `BufferReceiverToken` is invalidated on cleanup.
- **Subscriber-demand visualization** — `visualization.subscribe(request:)` declares what work is needed (`LODWork`); the engine only computes work that at least one subscriber requested.
- **Frame-scoped zero-copy LOD reads** — `WaveformView` uses `visualization.withCurrentLODSnapshotRef { ... }` inside a `TimelineView` so each draw reads the most-recent snapshot without allocation.
- **Microphone permission across iOS and macOS** — `PermissionGate.swift` handles both `AVAudioApplication.requestRecordPermission` (iOS) and `AVCaptureDevice.requestAccess(for: .audio)` (macOS).

## What it intentionally does NOT demonstrate

- Recording-list persistence, app capabilities beyond the microphone, audio-session category negotiation, segmented recording, frequency-domain analysis, beat detection. The library supports all of these; the sample stays small so the canonical idioms are easy to read.

## Run it

```bash
cd Packages/AIO/Examples/AudioIODemo
xcodegen generate
open AudioIODemo.xcodeproj
```

Or from the command line:

```bash
xcodebuild build -project AudioIODemo.xcodeproj -scheme AudioIODemo -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild build -project AudioIODemo.xcodeproj -scheme AudioIODemo -destination 'platform=macOS'
```

The Xcode project is generated from `project.yml`; it is gitignored, regenerate after pulling.

## Code signing

The sample is configured for ad-hoc "Sign to Run Locally" signing so it builds without a development team. To distribute the sample, override `CODE_SIGN_STYLE` and set `DEVELOPMENT_TEAM` in `project.yml` (or in the Xcode UI after generation).

## File map

| File | Lines | Role |
|---|---|---|
| `AudioIODemoApp.swift` | ~20 | `@main` App scene. |
| `ContentView.swift` | ~90 | The whole UI: header, waveform, controls, status. |
| `RecorderViewModel.swift` | ~120 | `@Observable @MainActor` engine adapter; subscribes to `events`. |
| `WaveformView.swift` | ~50 | `TimelineView` + `Canvas` reading the multi-band LOD snapshot. |
| `PermissionGate.swift` | ~50 | iOS / macOS microphone permission. |
| `project.yml` | ~60 | XcodeGen manifest. |
