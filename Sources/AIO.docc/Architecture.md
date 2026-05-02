# Architecture

AIO exposes three public SwiftPM products:

- `AIOEngine`: the public umbrella for recording, playback, session management,
  visualization, and signal-processing integration.
- `AudioSignals`: signal-processing types that can be used without the full engine.
- `Tools`: shared concurrency and utility primitives that are intentionally public when
  they appear in AIO's public contracts.

Internally, AIO is split by runtime ownership:

- `AIOContracts`: `BufferReceiver`, `BufferReceiverToken`, `BufferTiming`, and session
  delegate contracts.
- `AIOAudioSession`: input/output configuration, route/interruption state, and
  `AudioEnvironmentManager`.
- `AIOEngineCore`: the ``AIOEngine`` type, observable state, errors, and shared runtime
  context.
- `AIORecording`: recording lifecycle, tap setup, file writing, and receiver fan-out.
- `AIOPlayback`: file/segment playback and scrub coordination.
- `AIOVisualization`: ``AudioVisualizationEngine``, visualization demand resolution,
  and event fan-out.
- `AudioSignals`: multi-band LOD, time-domain, frequency-domain, beat, and offline
  extraction primitives.
- `AIOMicHealth`: signal-health monitoring.
- `AIOSupport` and `AIORecordingSupport`: package-internal support code.

## Public Boundary

Consumers should import `AIOEngine` first. Direct imports of subtargets are only needed
for narrow advanced use, such as depending on `AudioSignals` without recording/playback.

The umbrella intentionally re-exports the submodules whose public symbols are part of the
engine contract. Internal helpers stay `internal` or `package`; buffer receiver storage and
writer/runtime support are not public API.

## Topics

- <doc:SPEC_AIO>
- <doc:SPEC_AUDIO_VIZ>
- <doc:MultiBandVisualization>
- <doc:DESIGN_THREADING_CONFORMANCE>
- <doc:core-audio-layer-opportunities>
