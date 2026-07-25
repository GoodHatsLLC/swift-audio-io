# Audio Session

``AudioEnvironmentManager`` coordinates audio-session activation, input device selection, route changes, and interruption handling. The engine consumes this surface through narrow contracts so feature code never has to reach for `AVAudioSession` directly.

## What it owns

On iOS, ``AudioEnvironmentManager`` wraps `AVAudioSession` activation, category/mode configuration, available-input enumeration, and the route-change / interruption / media-services notification surface. On macOS, the same type provides a tap-reinstall-driven equivalent for route changes (macOS has no `AVAudioSession`-style interruption notifications).

## Audio system events

Route transitions, interruptions, and media-services changes share one
platform-neutral value interface:

```swift
let subscriberID = envManager.addAudioSystemEventSubscriber { event in
  await engine.handleAudioSystemEvent(event)
}

envManager.removeSubscriber(subscriberID)
```

These subscribers are fan-out by design — registering multiple subscribers does not displace existing ones, and unsubscribing is per-id.

``AudioSystemEvent`` contains captured values rather than a live platform
session. A caller can forward it to the engine, inspect it for UI, persist it
for diagnostics, or replay it in a deterministic test.

## Narrow protocol contracts

Feature code typically depends on one of these narrow contracts rather than the concrete `AudioEnvironmentManager`:

- ``AudioEnvironmentDriving`` — start/stop the environment, observe lifecycle.
- ``AudioEnvironmentConfiguring`` — query available inputs and configure category/mode.
- ``AudioEnvironmentEventSubscribing`` — subscribe to audio-system events.

These contracts let feature code stay testable without a real `AVAudioSession` and keep the platform asymmetries (iOS vs macOS) handled at the implementation, not the call site.

## Interruption interplay with recording

When the audio session reports an interruption while recording is active:

1. ``AudioEnvironmentManager`` translates the native notification into an ``AudioSystemEvent``.
2. The consumer forwards the value to ``AIOEngine/handleAudioSystemEvent(_:)``.
3. The engine's shared recovery policy decides whether to continue, stop, defer, or restart recording or playback.
4. Recoverable: the engine reinstalls the tap and emits ``AudioIOEvent/recordingInterruption(_:)`` with a `.routeChangeContinuing(...)` payload.
5. Unrecoverable: the engine stops recording, emits `.recordingInterruption(.stoppedByInterruption(reason:))`, then `.recordingFailed`.

The application's role is to subscribe to the events stream and drive UI. The engine's role is to make the right reconfiguration decision.

## Topics

### Manager

- ``AudioEnvironmentManager``

### Contracts

- ``AudioEnvironmentDriving``
- ``AudioEnvironmentConfiguring``
- ``AudioEnvironmentEventSubscribing``

### Input + route types

- ``AudioInput``
- ``AudioSource``
- ``AudioSystemEvent``
- ``AudioRouteChange``
- ``AudioRouteChangeReason``
- ``AudioRouteSnapshot``
- ``AudioPortSnapshot``
- ``AudioSessionSnapshot``
- ``PolarPattern``

### Errors

- ``SessionError``
- <doc:ErrorHandling>
