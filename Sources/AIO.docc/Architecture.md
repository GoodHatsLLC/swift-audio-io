# Architecture

This section documents the current AIO package architecture.

## Current Package Graph

The package exposes three public products:

*   **Tools**
*   **AudioSignals**
*   **AIOEngine** — the public compatibility facade and re-export layer

Internally, AIO is split by runtime ownership:

*   **AIOContracts** — `BufferReceiver`, `AudioSessionDelegate`, and related shared contracts
*   **AIOAudioSession** — session/environment/input/output runtime
*   **AIORecordingSupport** — recording-only state/support substrate shared by core and runtime layers
*   **AIOEngineCore** — core `AIOEngine` type and shared state
*   **AIORecording** — recording runtime, `RecordingEngineRuntime`, and tap lifecycle
*   **AIOPlayback** — playback runtime and scrub logic
*   **AIOVisualization** — live visualization runtime (`AudioVisualizationEngine`, `VisualizationProcessor`, `VisualizationHub`)
*   **AIOSupport** — package-internal logging/support code

## Refactor Status

As of 2026-03-23:

*   AppLibrary consumes AIO-owned runtime contracts instead of defining its own engine-facing protocols.
*   Visualization processing and subscriber/event fan-out are separated.
*   The optional target split has landed.
*   `AudioEnvironmentManager` now delegates session bootstrap/control, route observation, state projection, and preference restoration to focused collaborators.
*   Recording behavior now lives behind `RecordingRuntime` plus `RecordingEngineRuntime`, with `AIOEngine+Recording` acting as a forwarding surface.

Still in progress relative to `/Users/adamz/Developer/repos/audio/AIO_PROPOSAL.md` and
`/Users/adamz/Developer/repos/audio/AIO_EXECUTION_PLAN.md`:

*   `AIOEngineCore` still owns the shared observable state spine and some cross-runtime helpers.
*   `AIOEngine` remains source-compatible, but it is not yet the near-zero-state facade described in the proposal’s final state.

## Key Documents

*   <doc:SPEC_AIO>
*   <doc:SPEC_AUDIO_VIZ>
*   <doc:MultiBandVisualization>
*   <doc:DESIGN_THREADING_CONFORMANCE>
*   <doc:AUDIO_ENGINES>
*   <doc:core-audio-layer-opportunities>
