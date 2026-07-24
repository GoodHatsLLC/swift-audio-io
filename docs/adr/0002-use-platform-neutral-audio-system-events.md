---
status: accepted
---

# Use one platform-neutral audio system event interface

## Context

Audio environment notifications and engine recovery were exposed as four
platform-shaped callback families. iOS and macOS handlers repeated recording
abort, deferred restart, media-reset, and failure-event policy, while tests
needed private decision helpers or live `AVAudioSession` values. Consumers had
to understand which platform event method corresponded to each recovery path.

## Decision

`AudioEnvironmentManager.addAudioSystemEventSubscriber(_:)` is the sole event
subscription interface, and it produces captured `AudioSystemEvent` values.
`AIOEngine.handleAudioSystemEvent(_:)` is the sole recovery entry point.
`AudioRouteChange` carries neutral reason, route, port, and session snapshots;
no recovery decision requires a live platform session.

One concrete in-process interruption policy owns recording and playback
recovery decisions plus dedicated pending-restart state. Platform adapters only
translate native notifications into values. Recovery failures remain
nonthrowing at the handler interface and are published through
`AIOEngine.events`.

## Consequences

The change is source-breaking and intentionally replaces the platform-specific
handlers and four subscriber methods instead of layering aliases over them.
Tests and consumers cross the same single event seam. Native frameworks remain
inside event-capture adapters, while emitted recording-interruption outcomes
retain their existing semantics with a neutral route payload.
