# Events

``AIOEngine/events`` is the canonical engine notification surface. Subscribe once; pattern-match on the case you care about.

## The stream

```swift
for await event in engine.events {
  // …
}
```

The stream emits ``AudioIOEvent``, an enum with cases for every lifecycle transition and engine-level failure. Subscription is multi-consumer — every subscriber receives every event independently, in send order, through a per-subscriber unbounded buffer. The broadcaster does not replay events for late subscribers; subscribe before driving the engine if you need the first event.

## The cases

### Errors

- ``AudioIOEvent/error(_:)`` — every engine-level failure that the engine could not surface via a `throws` signature. See <doc:ErrorHandling> for the domain-typed payload shape.

### Recording lifecycle

- ``AudioIOEvent/recordingStarted(url:format:)`` — initial recording start, or a segment rotation (the rotated segment fires `recordingStarted` for the new URL).
- ``AudioIOEvent/recordingCompleted`` — a user-initiated stop completed cleanly.
- ``AudioIOEvent/recordingFailed`` — recording stopped due to an engine-side failure. Usually paired with an ``AudioIOEvent/error(_:)`` event describing the cause.
- ``AudioIOEvent/recordingInterruption(_:)`` — a route-change continuation, a graceful stop, or an interruption-driven stop. Carries an ``AIOEngine/RecordingInterruption`` payload describing the variant.
- ``AudioIOEvent/reconciliationFailed(desiredRecording:)`` — only fires when using the `@_spi(Advanced)` reconciliation-mode entry point ``AIOEngine/setDesiredRecordingState(_:configuration:)``. The canonical ``AIOEngine/startRecording(configuration:)`` returns failures directly via typed throws.

### Playback lifecycle

- ``AudioIOEvent/playbackStateChanged(_:)`` — play/pause/stop transitions, excluding time ticks.
- ``AudioIOEvent/playbackUpdated(_:)`` — every observation including time ticks. Mirror this into a local `@Observable` store if you need SwiftUI bindings to react to playback position.

## Replacing the old closure callbacks

The pre-`0.1.0` `on*` closure callbacks (`onRecordingStarted`, `onPlaybackUpdated`, etc.) are removed. The events stream is the only notification API. Migration is mechanical:

```swift
// Before (deleted):
engine.onRecordingStarted = { url, format in handle(url, format) }
engine.onRecordingFailed = { handleFailure() }

// After:
let task = Task { @MainActor in
  for await event in engine.events {
    switch event {
    case .recordingStarted(let url, let format): handle(url, format)
    case .recordingFailed: handleFailure()
    default: break
    }
  }
}
```

The multi-consumer broadcaster eliminates the "chained observer" pattern the old single-owner closures required. Multiple subscribers can run independently; each cancels its own subscription task without disturbing the others.

## Topics

### Stream

- ``AIOEngine/events``
- ``AudioIOEvent``
