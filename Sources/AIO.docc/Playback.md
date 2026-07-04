# Playback

File and segment playback with scrub support. Time coordinates are file-relative for whole-file playback and segment-relative for segments.

## Whole-file playback

```swift
let playback = try await engine.play(url: fileURL)
await engine.stopPlayback()
```

``AIOEngine/play(url:)`` returns the initial ``AIOEngine/Playback`` snapshot describing the current state. Subsequent observations arrive on the events stream as ``AudioIOEvent/playbackUpdated(_:)`` ticks.

## Segment playback

Segment playback keeps its public time coordinate segment-relative — `time` and `duration` are measured from the segment start, not the file start:

```swift
let playback = try await engine.playSegment(
  url: fileURL,
  startTime: 3,
  endTime: 8,
  playbackPollingInterval: .milliseconds(50),
)
_ = try engine.scrub(to: 1.5) // 1.5 seconds into the active segment
await engine.stopPlayback()
```

This shape lets segment-shaped UI controls (waveform timelines clipped to a region, snippet players) bind their progress bar to the playback `time` without translating coordinates.

## Scrubbing

``AIOEngine/scrub(to:mode:)`` reseeks the active playback to a time coordinate matching the active playback mode. For whole-file playback the coordinate is file-relative; for segment playback it's segment-relative and clamped to the segment range.

Use ``PlaybackScrubMode/interactive`` for scrub-during-drag interactions where you want to suppress the next polling tick that would otherwise overwrite your in-flight UI state. Use ``PlaybackScrubMode/committed`` for final drag releases and one-shot seeks so normal playback polling resumes immediately.

The lower-level ``AIOEngine/scrub(to:updatePlaybackPolling:)`` overload remains available when a caller needs to map a custom policy directly to playback polling.

## Audible jog

``AIOEngine/beginPlaybackJog(at:)`` starts a gesture-scoped audible preview transport beside normal playback. Jog uses the same public time coordinates as playback: file-relative for whole-file playback and segment-relative for segment playback.

```swift
_ = try engine.beginPlaybackJog(at: 1.2)
_ = try engine.updatePlaybackJog(rate: .normalReverse, anchorTime: 1.1)
_ = try engine.endPlaybackJog(commit: true)
```

Jog snapshots are emitted as ``AudioIOEvent/playbackJogUpdated(_:)`` rather than ordinary playback ticks. Consumers should treat them as interaction preview state, not Now Playing or resumable playback state. Releasing the gesture with `commit: true` seeks through the ordinary scrub path; `commit: false` restores the pre-jog position and play/pause state.

## Observing playback

Subscribe to ``AIOEngine/events`` for playback state:

| Event | When |
|---|---|
| ``AudioIOEvent/playbackStateChanged(_:)`` | Play/pause/stop transitions, excluding time ticks. |
| ``AudioIOEvent/playbackUpdated(_:)`` | Every observation including time ticks. |
| ``AudioIOEvent/playbackJogUpdated(_:)`` | Gesture-scoped audible jog preview updates. |

The playback cases coexist by design: state-driven UI (play/pause icon) binds to `playbackStateChanged`; tick-driven UI (progress bar, scrubber) binds to `playbackUpdated`. Mirror the `Playback?` payload into a local `@Observable` store if you need SwiftUI observation. Keep jog snapshots separate so interactive waveform preview does not churn normal playback state.

## Conflicts with recording

Playback and recording are mutually exclusive. Starting playback while recording is active throws ``PlaybackError/cannotPlayWhileRecording``. The engine does not implicitly stop recording to start playback — that's a caller decision.

## Topics

### Engine surface

- ``AIOEngine/play(url:)``
- ``AIOEngine/playSegment(url:startTime:endTime:playbackPollingInterval:)``
- ``AIOEngine/stopPlayback()``
- ``AIOEngine/scrub(to:mode:)``
- ``AIOEngine/scrub(to:updatePlaybackPolling:)``
- ``AIOEngine/beginPlaybackJog(at:)``
- ``AIOEngine/updatePlaybackJog(rate:anchorTime:)``
- ``AIOEngine/endPlaybackJog(commit:)``
- ``AIOEngine/cancelPlaybackJog()``
- ``AIOEngine/playback``
- ``AIOEngine/playbackJog``
- ``AIOEngine/isPlaying``
- ``AIOEngine/isPlayback``

### Snapshot

- ``AIOEngine/Playback``
- ``PlaybackJogRate``
- ``PlaybackJogSnapshot``

### Errors

- ``PlaybackError``
- <doc:ErrorHandling>
