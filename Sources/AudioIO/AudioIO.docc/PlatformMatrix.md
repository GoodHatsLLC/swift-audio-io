# Platform Matrix

AudioIO targets iOS 26+ and macOS 26+. Most APIs are platform-symmetric; the asymmetries are concentrated in the audio-session surface.

## Declared platforms

| Platform | Minimum | Status |
|---|---|---|
| iOS | 26.2 | Supported, gated by CI on iOS Simulator + real-device harness. |
| macOS | 26.2 | Supported, gated by CI on macOS host. |

Lowering either floor would require a SemVer-major release. We make no commitment to platforms outside iOS and macOS — see the project roadmap for the reasoning.

## What's iOS-only

The following surfaces are `#if os(iOS)`-gated and not available on macOS:

- `OrientationObserver`, which bridges UIKit device-orientation notifications.
- The `AVAudioSession` adapter that discovers and reconciles input data
  sources, polar patterns, channel counts, sample rates, and processing mode.

## What's macOS-only

- **System-audio capture** — the `RecordingInput.systemAudio` case and the `SystemAudioRecordingInput` / `SystemAudioProcessSelection` / `SystemAudioProcessObjectID` / `SystemAudioProcess` / `SystemAudioProcessCatalog` types are `#if os(macOS)` (Core Audio process taps have no iOS equivalent). A configuration that compiles on iOS can only select the microphone. See <doc:SystemAudioCapture>.

## What's symmetric

Everything else: ``AIOEngine`` recording and playback,
``AudioVisualizationEngine``, the events stream, the entire ``AudioIOError``
family, and the platform-neutral ``AudioSystemEvent`` / route snapshot values.
Native configuration and notification adapters differ, but consumers use the
same ``AudioEnvironmentConfiguring`` requested/applied state,
``AudioEnvironmentDriving/settleInputConfiguration()``,
``AudioEnvironmentManager/addAudioSystemEventSubscriber(_:)``, and
``AIOEngine/handleAudioSystemEvent(_:)`` interfaces on both platforms.

## CI gate

| Layer | Tool | Scope |
|---|---|---|
| SwiftPM tests | `xcrun swift test --package-path Packages/AIO` | macOS host; skips `#if os(iOS)` and `#if canImport(UIKit)` paths. |
| iOS Simulator unit tests | `xcodebuild test -scheme AIOiOSTests` | Compiles and runs all iOS-gated paths. |
| Integration tests | `xcodebuild test -scheme AIOPlatformIntegrationTests` | Drives real `AVAudioSession` route changes and interruptions. |

Any API-shape change should go through both the macOS host suite and the iOS Simulator build — the host suite alone does not exercise iOS-conditional code.
