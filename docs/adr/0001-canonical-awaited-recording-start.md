---
status: accepted
---

# Use one canonical awaited recording start

## Context

AudioIO exposed three overlapping ways to begin capture: a single-attempt start,
a desired-state reconciliation API, and partial warming. Consumers had to choose
which path was reliable enough, mirror intent into the engine, inspect a
separate failure slot, and wire audio-session activation after initialization.
The abstraction leaked platform readiness sequencing and let two owners disagree
about whether recording was desired.

## Decision

`AIOEngine.startRecording(configuration:)` is the sole public start operation.
It awaits end-to-end readiness, retries only transient session/source failures
within the engine's immutable deadline, and returns only after capture is
producing output. Terminal failure, timeout, cancellation, and competing starts
are distinct `RecordingError` cases.

The task awaiting start represents caller-owned recording intent. Cancelling it
withdraws that intent. `stopRecording()` applies only after start succeeds.
Startup failures are returned only through typed throws; lifecycle failure
events remain reserved for failures after recording has begun.

An engine receives an optional immutable `AudioSessionAuthority` at
initialization. Without one, the engine manages platform activation and
deactivation itself. Readiness implementation details live behind an internal
`AIORecording` port so the public lifecycle can be tested deterministically.

The desired-state, reconciliation, mutable session-delegate, and public warm
surfaces are removed in the same pre-1.0 migration.

## Consequences

Consumers have one deep start interface for microphone and system audio, and no
longer coordinate retries, partial readiness, or mirrored intent. The change is
source-breaking. Callers needing a longer readiness window choose it when the
engine is created. Concurrent starts are rejected rather than coalesced, and a
failed or cancelled start must clean up any output file it created.
