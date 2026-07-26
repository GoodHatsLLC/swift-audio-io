# Rotation boundary frame position + format concatenation facts

Date: 2026-07-25
Status: **implemented** — all three parts landed as proposed. Open questions
resolved below.

## Summary

Two small additions so a consumer can reassemble a rotated recording without
drift:

1. **`rotateRecordingFile()` and `stopRecording()` should both return the
   boundary frame position** — the cumulative persisted-sample position at which
   the completed file ends. The engine already computes this value on both
   paths; it just doesn't return it.
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

**`stopRecording()` changes the same way.**

```swift
/// The outcome of stopping a recording.
public struct RecordingCompletion: Sendable, Hashable {
  /// The final file of this capture.
  public let completedURL: URL

  /// Cumulative persisted-frame position at which `completedURL` ends —
  /// therefore also the total frame count of the whole capture, across every
  /// rotation.
  public let boundaryFramePosition: Int64
}

@MainActor
func stopRecording() async throws(RecordingError) -> RecordingCompletion
```

The final boundary is *technically* obtainable today —
`recordingTimingSnapshot()` is documented as remaining readable after stop, and
it is sound *there* because capture has ended. Returning it anyway is worth a
second source break for three reasons:

- **One mechanism instead of two.** Otherwise a consumer assembling a session
  reads N−1 boundaries from a return value and the Nth from a separate accessor
  whose soundness depends on a timing rule it has to know about. Two mechanisms
  for one concept is where the bugs live.
- **The soundness rule is invisible.** "This read is only correct after capture
  ends" is a real constraint that nothing in the type system expresses. A
  consumer that reasonably factors its stop and rotation handling into one code
  path silently gets a racy read on the rotation branch — which is exactly the
  defect this proposal exists to remove.
- **It closes the arithmetic.** With both returned, the final
  `boundaryFramePosition` is the capture's total frame count, so a consumer can
  assert its assembled segments sum to the whole. That check is the cheapest
  possible guard against a boundary bug, and it is unavailable if the last
  number arrives by a different route.

`stopAndDrainAll` already computes the value at
`RecordingLifecycle+Writer.swift:198`, the same way `enqueueDrain` does at
line 165.

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
**source-breaking** for conformers to and callers of `RecordingDriving`.
`stopRecording()` is the wider break of the two — every consumer calls it,
whereas rotation is only used by consumers that opted into it. Given
`Unreleased` already carries a source-breaking removal
(`RecordingInterruption.stoppedGracefully`), landing both in the same release
seems reasonable — one migration pass rather than two.

Migration is mechanical, and the compiler finds every site:

```swift
let url = try await engine.rotateRecordingFile()
let url = try await engine.stopRecording()
// become
let url = try await engine.rotateRecordingFile().completedURL
let url = try await engine.stopRecording().completedURL
```

`RecordingCompletion` and `RecordingRotation` are deliberately separate types
rather than one shared type. They carry the same fields today, but they answer
different questions — "where does this file end and the next begin" versus
"where does this capture end" — and merging them would invite a consumer to
treat a stop as a rotation. If that reads as over-modelling, one type named for
the shared fact (`RecordingSegmentBoundary`) is a reasonable alternative.

The format properties are purely additive.

## Tests

The current rotation tests (`AIOTests/AIOEngineIntegrationTests.swift:90`,
`:487`) assert that two distinct non-empty files are produced. They should be
extended, because boundary errors are invisible at this granularity:

- **Boundary monotonicity and totals** — across N forced rotations followed by a
  stop, assert the boundary sequence is strictly increasing and that
  `stopRecording()`'s boundary equals the capture's total frame count. With both
  calls returning boundaries this is pure arithmetic over the returned values,
  with nothing read out of band.
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

1. **Is `flac` truncation-tolerant in practice?** ~~The stream is frame-framed with
   sync codes, so many decoders will play a truncated file, but `STREAMINFO`'s
   total-samples field and the seektable are written at close.~~
   **Resolved: `false`.** The honest answer is "decoder-dependent", and the
   property is only useful if it is conservative.
2. **Is `recordingSampleTimeAtomic` the right counter to expose**, or should the
   boundary come from the completed writer session's final `writtenSampleTime`
   after its drain resolves?
   **Resolved: the drain target.** Two corrections to the framing above. First,
   the counters differ in one more case than "when a drain fails": the capture
   path increments `recordingSampleTimeAtomic` unconditionally, including for
   frames it *dropped* because the writer ring was full
   (`RecordingLifecycle+Capture.swift`), so under overflow the boundary
   overstates a file's decoded frame count. That is documented on the property
   — the boundary tracks the capture timeline, and a drop is a separately
   reported fault. Second, the achieved count is not merely a different read:
   rotation hands the old writer's drain to a background task and returns
   immediately, so sourcing the boundary from `writtenSampleTime` would mean
   awaiting that drain inside `rotate()` — adding drain latency to every
   rotation.
3. **One boundary type or two?**
   **Resolved: two.** `RecordingRotation` and `RecordingCompletion` as
   proposed, so a stop cannot be mistaken for a rotation.

*(Resolved: `stopRecording()` does change too — see the Proposed API section.)*

## What landing this turned up

The multi-rotation test the plan asks for ("across N forced rotations…")
immediately failed, and not on the boundary arithmetic — which was correct on
the first run — but on a latent engine defect the plan did not anticipate.

Drain targets are sampled from the capture-wide `recordingSampleTimeAtomic`,
but `Writer.runLoop` tracked `writtenSampleTime` as a per-file counter starting
at zero. The two domains coincide for the first file of a capture, which is why
the existing single-rotation tests (`AIOEngineIntegrationTests.swift`,
`AIOPlatformIntegrationTests.swift`) never saw it. From the second rotation on,
the target was unreachable: every drain waited out the full five-second
`writerDrainTimeout`, force-closed, and recorded a `WriteFailure` that the
following `stopRecording()` then had to explain away via its
"drain timed out but file exists with data" path.

The audio was never wrong — the writer keeps flushing until its ring empties —
which is exactly the plan's point that "boundary errors are invisible at this
granularity". `WriterSession` now carries the frame position its file starts at
and reports progress in the capture's domain. A three-rotation capture settles
in milliseconds rather than fifteen seconds.

Two further defects in the same area were fixed on top:

**A stop during a rotation's drain re-aimed it.** `stopAndDrainAll` set one
target — the capture's end — on every writer session, including ones a rotation
had already drained to their own boundary. Those frames went into the next
file's ring, so the completed writer could never reach the raised target: it
waited out `writerDrainTimeout` and reported a failure for a complete file. The
pre-existing `rotate recording file emits two files` test had been paying that
five seconds on every run, passing the whole time. A session that already has a
target now keeps it.

**The boundary was raced for rather than enforced.** Rotation sampled the
boundary, replaced the tap's ring buffers, and refreshed the tap's fallback
snapshot as three separate steps, so a capture callback could take its rings
from one side of the split and its frame position from the other — writing into
the completed file's ring while being counted past that file's boundary.

The first attempt was to make those three steps one `state` critical section.
That narrows the window but cannot close it, and the residue is instructive:
the tap must never block, so it reads its rings under `withLockIfAvailable` and
accounts for its frames *afterwards*. Nothing the rotation side holds orders
those two events. Worse, combining the steps means a callback arriving inside
the critical section misses both locks and drops its buffer — trading a
mis-numbered frame for a lost one.

The fix is to stop swapping. **Rotation is a change of consumer, not of
transport.** The tap keeps writing into the same rings across the boundary; the
completed writer stops reading at exactly `boundaryFramePosition`, leaving the
frames past it for the writer that takes over, and the two loops share a serial
queue so they never read it at the same time. The split is now enforced where
it is observed rather than raced for: no callback can be on the wrong side of
it, nothing is dropped, and a file is exactly as long as its boundary claims.
`receiverBuffers` already survived rotation untouched, which was the standing
proof the pattern works.

This also removes an older hazard on the same path — a writer loop could
previously still be writing when the satisfied drain closed the file underneath
it — and deletes the ring allocation and snapshot republishing from `rotate()`.
