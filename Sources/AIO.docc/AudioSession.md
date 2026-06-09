# Audio Session

``AudioEnvironmentManager`` coordinates audio-session activation, input device selection, route changes, and interruption handling. The engine consumes this surface through narrow contracts so feature code never has to reach for `AVAudioSession` directly.

## What it owns

On iOS, ``AudioEnvironmentManager`` wraps `AVAudioSession` activation, category/mode configuration, available-input enumeration, and the route-change / interruption / media-services notification surface. On macOS, the same type provides a tap-reinstall-driven equivalent for route changes (macOS has no `AVAudioSession`-style interruption notifications).

## Subscriber-based observation

Each notification surface is observable via an `add…Subscriber` registration:

```swift
let routeSubscriberID = envManager.addRouteChangeSubscriber { event in
  // route change observed
}

let interruptionSubscriberID = envManager.addInterruptionSubscriber { type, options in
  // iOS-only: AVAudioSession interruption observed
}

// Unsubscribe:
envManager.removeSubscriber(routeSubscriberID)
envManager.removeSubscriber(interruptionSubscriberID)
```

These subscribers are fan-out by design — registering multiple subscribers does not displace existing ones, and unsubscribing is per-id.

The engine itself subscribes to these notifications internally so that recording continues across route changes that don't require reconfiguration, and stops cleanly on unrecoverable interruptions. Application-level subscribers can register for the same notifications to drive UI (toast messages, recording-paused indicators).

## Narrow protocol contracts

Feature code typically depends on one of these narrow contracts rather than the concrete `AudioEnvironmentManager`:

- ``AudioEnvironmentDriving`` — start/stop the environment, observe lifecycle.
- ``AudioEnvironmentConfiguring`` — query available inputs and configure category/mode.
- ``AudioEnvironmentEventSubscribing`` — subscribe to route/interruption/media-services events.

These contracts let feature code stay testable without a real `AVAudioSession` and keep the platform asymmetries (iOS vs macOS) handled at the implementation, not the call site.

## Interruption interplay with recording

When the audio session reports an interruption while recording is active:

1. ``AudioEnvironmentManager`` notifies its interruption subscribers (including the engine).
2. The engine's interruption handler decides recoverable vs unrecoverable based on the cause.
3. Recoverable: the engine reinstalls the tap and emits ``AudioIOEvent/recordingInterruption(_:)`` with a `.routeChangeContinuing(...)` payload.
4. Unrecoverable: the engine stops recording, emits `.recordingInterruption(.stoppedByInterruption(reason:))`, then `.recordingFailed`.

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
- ``AudioRouteChangeEvent``
- ``PolarPattern``

### iOS-only

- ``AudioInterruptionType``
- ``AudioInterruptionOptions``

### Errors

- ``SessionError``
- <doc:ErrorHandling>
