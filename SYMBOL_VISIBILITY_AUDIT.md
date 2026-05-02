# AIO Symbol Visibility Audit

Date: 2026-05-02

This audit covers `Packages/AIO/Sources` after the AIO public-readiness pass. AIO
uses an umbrella target (`AIOEngine`) that intentionally re-exports focused
submodules, so a broad `public` search is only a starting point.

## Export Policy

- Stable public API is the API reachable from the SwiftPM library products:
  `AIOEngine`, `AudioSignals`, and `Tools`.
- `AIOEngine` intentionally re-exports `AIOAudioSession`, `AIOContracts`,
  `AIOEngineCore`, `AIOMicHealth`, `AIOPlayback`, `AIORecording`,
  `AIOVisualization`, and `AudioSignals` so one `import AIOEngine` is enough for
  common consumers.
- DEBUG testing hooks under `@_spi(TESTING)` are not semver-stable public API.
  They stay SPI-public because the workspace-only platform integration scheme is
  outside the SwiftPM package boundary.
- Recorder-specific adapter protocols such as `RecordingDriving`,
  `AudioEnvironmentDriving`, and `OutputConfigurationProviding` are currently
  public because AppLibrary consumes them across package boundaries. They are a
  future relocation candidate, not an accidental one-line visibility leak.

## Changes Made

- Hid the stale standalone `AIOAudioSession.AIOError` type. The supported public
  error type for engine operations is `AIOEngine.AIOError`.
- Hid `PlatformDeviceInfo`, `StereoOrientation`, and their platform
  implementations. They are audio-session implementation plumbing and are not
  referenced outside `AIOAudioSession`.

## Retained Public Surface

- `RecordingConfiguration`, `InputConfiguration`, `OutputConfiguration`, route
  and interruption snapshots, and environment managers remain public because they
  are part of the current recording/session configuration surface.
- `BufferReceiver`, `BufferReceiverToken`, `BufferTiming`, and visualization work
  types remain public because they are used by the documented live visualization
  quickstart.
- `AudioSignals` processing and snapshot types remain public because
  `AudioSignals` is a declared SwiftPM library product.
- `Tools` public concurrency and utility types remain public because `Tools` is a
  declared SwiftPM library product and several exported AIO types expose
  `Tools.AudioError` / `Tools.ErrorContext`.
