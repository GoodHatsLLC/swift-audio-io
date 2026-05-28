# Changelog

All notable changes to AudioIO are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com) categories, and
releases follow the versioning policy in `README.md` and `ROADMAP.md`.

## Unreleased

Nothing yet.

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

Initial public release, extracted from the Recorder‽ app. This is the start of the
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
