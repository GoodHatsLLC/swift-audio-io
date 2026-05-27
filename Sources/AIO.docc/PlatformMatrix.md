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

- ``AudioInterruptionType`` and ``AudioInterruptionOptions``, plus interruption-handling on ``AudioEnvironmentManager``. macOS has no equivalent of `AVAudioSession`'s interruption notifications.
- The `AudioPortSnapshot` / `AudioRouteSnapshot` / `AudioSessionSnapshot` introspection types.
- ``OrientationObserver``, which bridges UIKit device-orientation notifications.
- The iOS-only `InputPicker` UI in adopter apps (not part of AudioIO itself).

## What's macOS-only

- ``AIOEngine/handleRouteChange(event:)`` reaches a macOS-specific code path for engine-driven tap reinstall; the iOS path goes through `AVAudioSession` notifications subscribed via ``AudioEnvironmentManager``.

## What's symmetric

Everything else: ``AIOEngine`` recording and playback, ``AudioVisualizationEngine``, the events stream, and the entire ``AudioIOError`` family.

If you write generic code over `AudioEnvironmentConfiguring` and the AppLibrary-aware `AudioInputPickingEnvironment`, your callers will compile on both platforms — on macOS the picking-environment alias falls back to the base configuring protocol.

## CI gate

| Layer | Tool | Scope |
|---|---|---|
| SwiftPM tests | `xcrun swift test --package-path Packages/AIO` | macOS host; skips `#if os(iOS)` and `#if canImport(UIKit)` paths. |
| iOS Simulator unit tests | `xcodebuild test -scheme AIOiOSTests` | Compiles and runs all iOS-gated paths. |
| Integration tests | `xcodebuild test -scheme AIOPlatformIntegrationTests` | Drives real `AVAudioSession` route changes and interruptions. |

Any API-shape change should go through both the macOS host suite and the iOS Simulator build — the host suite alone does not exercise iOS-conditional code.
