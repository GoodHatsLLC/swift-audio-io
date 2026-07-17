# Changelog

All notable changes to AudioIO are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com) categories, and
releases follow the versioning policy in `README.md` and `ROADMAP.md`.

## Unreleased

Nothing yet.

## 0.8.0 - 2026-07-17

### Added

- `RecordingTimingSnapshot` now reports the last persisted-buffer host time,
  exact persisted frame count, and exact frame count spanning the measured host
  interval. Multi-device clients can use the interval to measure effective
  capture rate without estimating from file duration or counting dropped tap
  callbacks.

## 0.7.0 - 2026-07-16

### Changed

- Audio-session activation and deactivation now use async AudioIO APIs and run
  the blocking iOS `AVAudioSession.setActive` operation on AudioIO's serialized
  off-main session queue. `AudioEnvironmentManager.setAudioSessionActive`,
  `AudioSessionDelegate.setAudioSessionActive`, and `AIOEngine.warm` are now
  async so callers can suspend without blocking the main thread.

## 0.6.0 - 2026-07-14

### Added

- Added `AudioChannelConfigurationAvailability` and
  `AudioEnvironmentConfiguring.channelConfigurationAvailability` so clients can
  distinguish an unresolved input from a fixed mono/stereo input or an input
  whose channel configuration is user-selectable. The capability follows the
  system-default input without pinning it as a preferred device.

## 0.5.4 - 2026-07-08

### Fixed

- macOS: an input-route change (device added/removed, default input changed)
  during a system-audio recording no longer reinstalls the AVAudioEngine input
  tap. Previously the route-change handler treated every active recording as a
  microphone recording: it started the microphone and overwrote the shared tap
  converter, so the system-audio file silently captured microphone audio (or
  went silent). `reinstallTap` now also refuses system-audio configurations
  outright.
- macOS: `AudioEnvironmentManager` no longer pins a concrete input device when
  the selection is "system default" (`selectedInput == nil`). Refreshes keep
  `nil` selections so recordings follow default-input changes, a disappeared
  explicit selection falls back to the system default instead of an arbitrary
  remaining device, and the explicit selection re-attaches when its device
  returns.

### Added

- macOS: a diagnostic warning is logged when system-audio self-exclusion cannot
  resolve the host's HAL process object and falls back to bundle-identifier
  exclusion.

## 0.4.0 - 2026-07-03

### Added

- Added `PlaybackScrubMode` and `AIOEngine.scrub(to:mode:)` so callers can
  express interactive drag scrubs separately from committed seeks without
  reaching for playback-polling internals.

## 0.1.1 - 2026-05-28

### Fixed

- Paused playback now reports the current position instead of resetting
  `AIOEngine.Playback.time` to the segment start frame. While an
  `AVAudioPlayerNode` is paused it cannot report `lastRenderTime`, so
  `getPlayback(for:)` previously fell back to the start frame on every poll;
  it now returns the last observed position for the active playback instance.
  Consumers driving a playhead from `Playback.time` no longer see it jump to
  the start of the track on pause.

## 0.1.0 - 2026-05-28

Initial public release. This is the start of the
`0.x` line — the public API may change between minor versions until `1.0.0`.

### Added

- **`AudioIO`** umbrella product: recording, playback, audio-session coordination,
  real-time visualization, and microphone-health monitoring, driven through a single
  `AIOEngine`.
- **`AudioSignals`** product: signal-domain data types (`TimeDomainData`,
  `FrequencyDomainData`, `BeatInfo`) and multi-band LOD waveform extraction
  (`MultiBandLODProcessor`, `OfflineLODExtractor`), usable without the recording stack.
- **`Tools`** product: async/concurrency primitives (`AsyncBroadcaster`, `Subject`,
  `SPSCRingBuffer`) surfaced because they appear in AudioIO's public contracts.
- Unified `AIOEngine.events: AsyncBroadcaster<AudioIOEvent>` stream carrying every
  engine-level error and recording/playback lifecycle transition.
- Per-domain typed errors (`RecordingError`, `PlaybackError`, `SessionError`) under
  the `AudioIOError` marker protocol.
- Canonical `startRecording(configuration:) async throws(RecordingError) -> URL`
  entry point; reconciliation-mode recording behind `@_spi(Advanced)`.
- DocC catalog with externally-focused topics (Getting Started, Platform Matrix,
  Threading Model, Error Handling, Events) and per-surface reference docs.
- `Examples/AudioIODemo`: a minimum-viable iOS + macOS sample app.
- Apache-2.0 license.

### Platforms

- iOS 26+, macOS 26+. Swift 6.2 with strict concurrency.
