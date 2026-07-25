# Rotation boundary frame position + format concatenation facts

Date: 2026-07-25
Status: **proposed**

## Summary

Two small additions so a consumer can reassemble a rotated recording without
drift:

1. **`rotateRecordingFile()` and `stopRecording()` should return the boundary
   frame position** — the cumulative persisted-sample position at which the
   completed file ends and the next one begins. The engine already computes this
   value; it just doesn't return it.
2. **Two orthogonal facts on `FileFormat`** — whether a truncated file is still
   valid, and whether decoded output is frame-identical to the PCM written.

Plus one doc fix: `RecordingTimingSnapshot.capturedFrameCount` is documented as
being "for this segment", which is not true after a rotation.

## Motivation

A consumer that uses file rotation for crash-safety wants to treat the resulting
files as one continuous recording. Doing that correctly requires knowing exactly
where each file ends in the capture stream. Today it cannot.

Rotation itself is already excellent for this: `rotate()` prepares the new writer
*first*, enqueues a drain of the old one so its buffered frames still land in the
old file, then swaps `recordingWriter` / `recordingURL` / `audioBuffers` under
lock while the tap keeps running (`RecordingLifecycle+Rotation.swift:84-127`).
Capture never stops, and no frame is dropped or double-written. The audio is
sample-continuous across the boundary. **Only the reporting is missing.**

This is not a request for the engine to know about timelines, clips, or
assembly — those stay in application code per `NOT_AUDIO_IO.md`. It is a request
for the engine to report a fact about *its own writes* that only it can know.

## The problem, precisely

`rotateRecordingFile()` returns only the completed `URL`
(`Sources/AudioIO/Contracts/RuntimeDriving.swift:100`). To locate the boundary a
consumer must read `recordingTimingSnapshot()` separately, and that read is
unsound for three independent reasons:

**1. The capture counter never resets at rotation.** `resetRecordingTiming()` is
called from `RecordingLifecycle+Capture.swift` (lines 59, 314, 347) but **never
from `RecordingLifecycle+Rotation.swift`**. So `capturedFrameCount` keeps
climbing across rotations and is session-cumulative, not per-segment — despite
the doc comment on `RecordingTimingSnapshot.capturedFrameCount`
(`AIOContracts/BufferReceiver.swift:125-128`) saying "for this segment", which
holds only in the start/stop case. A consumer reading it as a segment length
after a rotation is wrong by the length of the entire preceding session.

**2. The read races the capture callback.** `recordPersistedBufferTiming` runs on
the capture path throughout the rotation, so any value sampled after `rotate()`
returns already includes an unknown number of frames belonging to the *new*
file. The error is bounded by buffer size and scheduling delay, but it is **per
boundary and cumulative** — which is the definition of drift.

**3. Even sampling inside the swap would be wrong.** At the moment of the swap,
frames are still sitting in the old ring buffer awaiting drain. They belong to
the *old* file but have already been counted. A consumer cannot compensate for
this from outside; it does not know the backlog depth.

## The value already exists

`enqueueDrain` computes exactly the right number and then discards it:

```swift
// Sources/AIORecording/RecordingLifecycle+Writer.swift:164-171
package func enqueueDrain(for session: WriterSession) {
  let target = owner.recordingSampleTimeAtomic.load(ordering: .relaxed)   // ← this
  prepareDrain(for: session, targetSampleTime: target, ...)
  ...
}
```

`recordingSampleTimeAtomic` is the cumulative count of frames enqueued to the
writer by the capture path (`RecordingLifecycle+Capture.swift:814`), reset at
capture start by `resetRecordingTiming()`. The drain loop then runs the old
writer until `writtenSampleTime >= target`
(`RecordingLifecycle+Writer.swift:306, 332`).

So `target` **is** the boundary, by the engine's own definition: it is the
position the completed file is drained *to*, and therefore the position the next
file begins at. It is sound where an external read is not, because it is sampled
on the same code path that decides the split, and it already accounts for the
undrained backlog. `stopAndDrainAll` computes the same thing at line 198.

## Proposed API

### 1. Boundary reporting

```swift
/// The outcome of a recording-file rotation.
public struct RecordingRotation: Sendable, Hashable {
  /// The file that was just completed.
  public let completedURL: URL

  /// Cumulative persisted-frame position, measured from the start of this
  /// capture, at which `completedURL` ends and the next file begins.
  ///
  /// Consecutive rotations produce a strictly increasing sequence, so a
  /// consumer can reconstruct each file's exact frame length as the difference
  /// between adjacent boundaries. The value is sampled where the split is
  /// decided, so it accounts for frames still awaiting drain into
  /// `completedURL`.
  public let boundaryFramePosition: Int64
}

@MainActor
func rotateRecordingFile() async throws(RecordingError) -> RecordingRotation
```

`stopRecording()` needs the same information for the final segment. It is
currently obtainable — `recordingTimingSnapshot()` is documented as remaining
readable after stop, and it is sound *there* because capture has ended — but
returning it symmetrically would let a consumer use one mechanism for every
boundary instead of two:

```swift
@MainActor
func stopRecording() async throws(RecordingError) -> RecordingCompletion
// { completedURL, boundaryFramePosition }
```

### 2. Format facts

Two orthogonal properties on `FileFormat`, in the style of the existing
`requiresQuality` / `maximumRecordingChannelCount`:

```swift
/// Whether a file truncated mid-write remains valid up to the truncation
/// point — i.e. whether the format is self-framing rather than dependent on
/// a header or index finalized at close.
public var toleratesTruncation: Bool

/// Whether decoding the written file yields exactly the frames that were
/// written, with no encoder priming or trailing padding.
public var preservesExactFrameCount: Bool
```

Proposed values:

| Format | `toleratesTruncation` | `preservesExactFrameCount` | Note |
|---|---|---|---|
| `wav`, `aiff` | `false` | `true` | Header declares a length fixed at close |
| `caf` | `false` | `true` | Same |
| `flac` | **?** | `true` | Lossless, so frame-exact. Truncation tolerance is the open question below |
| `aac` (m4a) | `false` | `false` | No `moov` until close; encoder priming + tail padding to a whole 1024-frame AAC frame |
| `adts` | `true` | `false` | Self-framing — every AAC frame carries its own header. But no container metadata to declare priming |

These are facts about the writer and the format, not about any consumer's use of
them, which is why they belong here rather than in a `switch` in every
application. A consumer composes its own policy from them: "rotate for
crash-safety" wants `!toleratesTruncation`; "reassemble losslessly" wants
`preservesExactFrameCount`.

### 3. Doc fix

`RecordingTimingSnapshot.capturedFrameCount` should say that it is cumulative
for the capture, not per-segment, and that it resets only at capture start.
Either that, or `rotate()` should call `resetRecordingTiming()` — but **not
that**, see below.

## Alternatives considered

**Add `lastRotationBoundary() -> Int64` and leave the signatures alone.**
Smaller blast radius, no source break. Rejected: it reintroduces a read that is
only correct at one moment, which is the shape of the current bug. Returning the
value from the call that produces it makes misuse hard.

**Call `resetRecordingTiming()` from `rotate()` so `capturedFrameCount` becomes
genuinely per-segment.** Rejected: it would make the counter match its
documentation but silently change the meaning of `recordingTimingSnapshot()` for
existing consumers mid-capture, and it would destroy `firstBufferHostTime` for
the capture as a whole, which multi-device alignment depends on. The
session-cumulative behaviour is the more useful one; the documentation should
follow the code.

**Have the engine expose an assembled multi-file recording.** Rejected as out of
scope — that is timeline assembly, which `NOT_AUDIO_IO.md` places in application
code. This proposal deliberately reports a number and stops.

## Source compatibility

Changing the return type of `rotateRecordingFile()` and `stopRecording()` is
**source-breaking** for conformers to and callers of `RecordingDriving`. Given
`Unreleased` already carries a source-breaking removal
(`RecordingInterruption.stoppedGracefully`), landing this in the same release
seems reasonable. Migration is mechanical:

```swift
let url = try await engine.rotateRecordingFile()
// becomes
let url = try await engine.rotateRecordingFile().completedURL
```

The format properties are purely additive.

## Tests

The current rotation tests (`AIOTests/AIOEngineIntegrationTests.swift:90`,
`:487`) assert that two distinct non-empty files are produced. They should be
extended, because boundary errors are invisible at this granularity:

- **Boundary monotonicity and totals** — across N forced rotations, assert the
  boundary sequence is strictly increasing and that the final boundary equals
  the capture's total frame count. Pure arithmetic over the returned values.
- **Boundary matches persisted frames** — assert each file's actual decoded frame
  count equals the difference between adjacent boundaries. This is the assertion
  that would have caught the race; it fails today for any read taken outside the
  swap.
- **Signal continuity** — using the deterministic test seam
  (`AIOEngine+Testing.startTestRecording` / the injected timing controls), feed a
  continuous full-scale sine through a capture with forced rotations, concatenate
  the outputs, and assert phase continuity across every boundary. A dropped or
  duplicated frame is a discontinuity; a placement error is a phase step.

## Open questions

1. **Is `flac` truncation-tolerant in practice?** The stream is frame-framed with
   sync codes, so many decoders will play a truncated file, but `STREAMINFO`'s
   total-samples field and the seektable are written at close. The honest answer
   may be "decoder-dependent", in which case `toleratesTruncation` should be
   `false` — the property is only useful if it is conservative.
2. **Is `recordingSampleTimeAtomic` the right counter to expose**, or should the
   boundary come from the completed writer session's final `writtenSampleTime`
   after its drain resolves? The drain target is available immediately and is the
   *intended* boundary; the written count is the *achieved* one and differs only
   when a drain fails — which is already surfaced as an error. The drain target
   seems better, but the maintainer knows the failure modes.
3. **Should `stopRecording()` change at all**, given the post-stop snapshot read
   is already sound? Symmetry is the only argument, and it costs a second source
   break.
