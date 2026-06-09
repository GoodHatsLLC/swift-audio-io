# Error Handling

AudioIO uses typed throws for synchronous failures and the unified events stream for failures that originate off the call site.

## The two failure paths

Every engine-level failure surfaces in exactly one of two places:

1. **Typed `throws`** on the call site, when the failure is detected during the call's own execution. Example: a malformed ``RecordingConfiguration`` is rejected by ``AIOEngine/startRecording(configuration:)`` before any tap is installed.
2. **The events stream** as an ``AudioIOEvent/error(_:)`` case, when the failure originates on the real-time tap thread, during async drain, or during session deactivation after a state transition.

You never need to inspect both paths for the same operation. The throws path describes "the call could not begin"; the events path describes "the call began but the engine subsequently surfaced a failure."

## The domain error families

All engine errors conform to the marker protocol ``AudioIOError``. Three domain enums implement it:

| Domain | Type | Typical sources |
|---|---|---|
| Recording | ``RecordingError`` | Tap install, channel validation, file write, session bring-up. |
| Playback | ``PlaybackError`` | File read, scrub validation, conflict with active recording. |
| Audio session | ``SessionError`` | Session activation, engine start, route reconfiguration. |

Cross-domain wrapping happens via `.session(_:)` cases on ``RecordingError`` and ``PlaybackError`` so a session failure surfaces with its category preserved. For example, a recording start that fails because `AVAudioEngine.start()` rejected the configured session arrives as `RecordingError.session(.engineStartFailed(error:))`.

## Reading errors

When you catch a typed throw:

```swift
do {
  let url = try await engine.startRecording(configuration: configuration)
  // …
} catch RecordingError.unsupportedChannelCount(let requested, let maximum) {
  // user-fixable: surface "this format supports at most \(maximum) channels"
} catch let error as RecordingError {
  // recording-domain failure with a stable case set
} catch {
  // engine-level guarantees keep this branch unreachable in practice
}
```

When you observe the events stream:

```swift
for await event in engine.events {
  guard case .error(let error) = event else { continue }
  switch error {
  case let recordingError as RecordingError:
    // …
  case let sessionError as SessionError:
    // …
  default:
    // any future AudioIOError-conforming error
    break
  }
}
```

The events-stream `error` payload is `any AudioIOError`, not `any Error` — the engine emits only `AudioIOError`-conforming values, so the type-erased switch is exhaustive against the documented surface.

## Capture-source failures and retry

System-audio capture (see <doc:SystemAudioCapture>) adds three terminal
``RecordingError`` cases:

- ``RecordingError/captureSourceUnavailable(details:)`` — the source can't be
  used (e.g. the audio-recording permission was denied). Retrying without user
  action is noise.
- ``RecordingError/captureSourceFailed(sourceDescription:details:)`` — the source
  failed in a way the caller must resolve by changing the source, its options, or
  the format. The payload is a short *description string* rather than the source
  enum, to keep equality, error output, and ABI stable.
- ``RecordingError/coreAudioFailed(operation:osStatus:details:)`` — a Core Audio
  (HAL) `OSStatus` with no more specific mapping; always surfaced rather than
  swallowed.

These are *terminal*: ``RecordingError/isTransient`` is `false` for them, so the
reconciliation start API (see <doc:SystemAudioCapture>) does not retry them. Only
a narrow set of HAL *not-ready* startup statuses is transient — those map to
`.session(.notReady(details:))` so the existing retry gate applies. This keeps
the OSStatus-to-`RecordingError` mapping the single source of truth for the retry
decision.

## Topics

### Error types

- ``AudioIOError``
- ``RecordingError``
- ``PlaybackError``
- ``SessionError``

### Adjacent surfaces

- <doc:Events> — the stream that carries ``AudioIOEvent/error(_:)``.
