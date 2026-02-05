# Waveform Visualization: Memory + Performance Follow-ups

**Last updated:** 2026-01-17

This doc captures next-step optimizations for waveform visualization, focused on **memory** first, then GPU/CPU/energy.

## Current Surfaces (Context)

Waveforms show up in three main ways:

1. **Static HEIC image** (`MetalWaveformImageView`) used in lists and some editors.
2. **Image-based scrubbing** (`TrackWaveformView`, via provider) that scrolls a wide base waveform.
3. **Metal waveform** (`MetalWaveformView` + `viz.metal`) used for interactive, zoomable detail views and some editor surfaces.

See `docs/SPEC/waveform-and-segment-editing-infrastructure.md` and `Packages/AppLibrary/Sources/AppLibrary.docc/2025-12-09-waveform-heic-migration.md` for the broader architecture.

## What Was Just Fixed

### 1) Avoid decoding full HEIC into memory for small views

Problem: `UIImage(contentsOfFile:)` eagerly decodes (potentially) the full HEIC into an uncompressed bitmap, which is expensive when list rows show many waveforms.

Implemented:
- `MetalWaveformImageView` now decodes a **thumbnail** via `CGImageSourceCreateThumbnailAtIndex` sized to the view’s pixel footprint, and caches thumbnails in-memory.
- File: `Packages/AppLibrary/Sources/WaveformMetal/MetalWaveformImageView.swift`

### 2) Cap offline Metal snapshot memory growth with recording length

Problem: `MultiBandLODSnapshot` stores `[Float]` buffers and can grow with duration (`bands * lodLength * 3`).

Implemented:
- Choose an adaptive `lodRatio` for offline snapshot generation to keep `lodBufferLength` bounded.
- Files:
  - `Packages/AppLibrary/Sources/WaveformMetal/WaveformLODHeuristics.swift`
  - `Packages/AppLibrary/Sources/AppTarget/Detail/DetailPlayerView.swift`
  - `Packages/AppLibrary/Sources/AppTarget/Detail/SegmentEditWaveformView.swift`

## Remaining High-Value Improvements (Prioritized)

## 0) Metal waveform flicker while panning (sampling stability)

Symptom: while panning/scrolling at a fixed zoom level, the Metal waveform “sparkles”/flickers even though no new audio data is arriving.

This is usually a **sampling stability** issue (pixel ↔ LOD index mapping) rather than a content issue.

### Likely root causes

1. **Non-integer drawable size / width mismatch**
   - The renderer draws `vertexCount = Int(drawableSize.width) * 6` columns, but the shader uses `u.screenWidth` as a float in LOD mapping.
   - If `drawableSize.width` is not an integer pixel width (or is being quantized inconsistently), the mapping can “breathe” by ±1 column as you pan.
   - Fix: ensure `MTKView.drawableSize` is set to **integer pixel dimensions** (rounded) and keep shader `screenWidth` consistent with that.

2. **Sampling at pixel edges instead of pixel centers**
   - In `viz.metal`, the mapping uses `pixelsFromRight = u.screenWidth - float(pixelX)`.
   - With `pixelX` representing a pixel column, sampling at the column’s edge tends to amplify temporal aliasing when the pan offset moves continuously.
   - Fix: sample at pixel centers:
     - `float pixelCenterX = float(pixelX) + 0.5;`
     - `float pixelsFromRight = u.screenWidth - pixelCenterX;`

3. **`floor/ceil` index selection near integer boundaries**
   - The shader uses `floor()` and `ceil()` to pick `readIdx0`/`readIdx1`.
   - When `lodSamplesAgo` is very close to an integer (common during smooth scroll), floating-point precision can cause the “fractional part” to flip sides frame-to-frame, producing visible toggling.
   - Fix: compute indices with a single `floor` and derive the second index deterministically:
     - `int i0 = int(floor(lodSamplesAgo));`
     - `int i1 = min(i0 + 1, lodLength - 1);`
     - `float frac = lodSamplesAgo - float(i0);`

4. **ViewOffset not aligned to LOD/sample grid**
   - `viewOffset` is in raw samples and is a `float`; panning can produce sub-sample deltas, which is fine, but if combined with edge sampling it can appear as shimmer.
   - Fix: after moving to pixel-center sampling and stable index math, consider quantizing `viewOffset` to a small grid only if needed:
     - e.g. quantize to `1/4` LOD sample in raw-sample space: `step = lodRatio / 4`.

### Recommended debugging steps

- **Lock `drawableSize`**: log `uiView.drawableSize` each frame while panning; verify it is constant and integer-valued.
- **Lock time-varying inputs**: temporarily fix `viewOffset` and pan via synthetic changes to confirm it’s not a data race.
- **Add a “sampling heatmap” debug mode** in `viz.metal`:
  - color by `frac` or by `readIdx0 % N` to see if indices are toggling unexpectedly.

### Concrete fixes to try (in order)

1. Round `drawableSize` to integer pixels in `MetalWaveformViewRepresentable.updateUIView`.
2. Update the shader mapping to pixel centers (`+0.5`).
3. Replace the `ceil()` logic with `i1 = i0 + 1` and `frac = lodSamplesAgo - i0`.
4. Optional: quantize `viewOffset` grid while panning (only if shimmer remains).

**Status:** steps 1 and 3 are implemented; pixel-center sampling (step 2) is still pending. If flicker persists after that, the next knob to try is optional `viewOffset` quantization and/or a debug “sampling heatmap” mode in `viz.metal`.

## A) Stop rendering full-frame Metal when nothing changes (energy + transient memory)

`MetalWaveformView` currently drives `MTKView` at 60fps while visible, even when the view is effectively static (common in detail screens when paused).

### Recommendation

In `MetalWaveformViewRepresentable` (`Packages/AppLibrary/Sources/WaveformMetal/MetalWaveformView.swift`):

- Set:
  - `mtkView.isPaused = true`
  - `mtkView.enableSetNeedsDisplay = true`
- Call `uiView.setNeedsDisplay()` only when inputs change:
  - snapshot identity / writeIndex changes,
  - `zoom`, `offset`, `palette`, `renderMode`, `separation`,
  - size / `drawableSize` changes.

For live/recording mode, keep continuous rendering enabled.

**Status:** implemented (2026-01-08)
- Static snapshots now pause `MTKView` and redraw only on input changes.
- Live snapshots (`LODSnapshotRef`) keep continuous rendering enabled.

### Why this helps memory

Even if per-frame allocations are “small”, sustained 60fps rendering increases transient pressure (autorelease pools, Metal driver allocations, texture churn) and amplifies spikes during scrolling.

## B) Reduce GPU memory for non-HDR / small waveforms

`MetalWaveformView` currently uses:
- `colorPixelFormat = .rgba16Float`
- `sampleCount = 4` (MSAA)

This is great for HDR beauty shots, but expensive as a default.

### Recommendation

Introduce a render-quality policy:

- Default (most UI):
  - `pixelFormat = .bgra8Unorm`
  - `sampleCount = 1`
  - `wantsExtendedDynamicRangeContent = false`
- High quality (explicitly requested):
  - keep `.rgba16Float`, enable EDR, and optional MSAA.

Additionally, clamp render resolution for small embeddings:
- Prefer rendering at `min(screenScale, 2.0)` for waveform-only content unless the user is actively zooming.

**Status:** implemented (2026-01-08)
- `MetalWaveformView` now defaults to `pixelFormat = .bgra8Unorm_srgb` and `sampleCount = 1`.
- Opt into HDR/MSAA via `MetalWaveformRenderQuality.high` (uses `.rgba16Float` + 4x MSAA + EDR).

## C) Prefer HEIC + crop over offline full-file snapshots for “full duration” views

Even with an adaptive `lodRatio`, full-file offline snapshots are still “duration-scaled” work and storage in memory.

### Recommendation

Adopt a ladder consistently:

1. **Zoomed out / overview:** show HEIC (`MetalWaveformImageView`) and crop/scroll (cheap).
2. **Zoomed in / editing:** render Metal only for the visible time window (see next section).
3. **While loading:** show placeholder/HEIC until windowed LOD is ready.

This is already the intended direction for clips (`MetalClipWaveformThumbnailView`)—apply the same rule to the big waveform surfaces.

## D) Windowed LOD snapshots (correctness + bounded memory)

Instead of generating LOD for the entire track, generate LOD only for the visible time range (plus a small prefetch margin).

### Implementation sketch

Create a `WindowedWaveformSnapshotProvider` that:
- Tracks current viewport time range (derived from zoom/offset + duration).
- Requests a snapshot for `[t0, t1]` plus margin (e.g. ±1–2 seconds).
- Caches snapshots with an LRU:
  - key: `(audioSourceId, startMsBucket, endMsBucket, bandCount, lodRatio)`
  - bucket time to reduce churn while panning (e.g. 250ms or 500ms buckets).
- Enforces a global memory cap (e.g. 32–64MB total).

You can reuse the approach in `Packages/AppLibrary/Sources/WaveformMetal/MetalClipWaveformThumbnailView.swift`:
- It already has a pooled renderer and snapshot cache keyed by time range.

### Key tradeoffs

- Time-bucketing introduces slight reuse artifacts at boundaries if the user is scrubbing rapidly; fix by:
  - using a small bucket size while playing/scrubbing,
  - using a larger bucket size when idle.

## E) Make HEIC generation/render options list-friendly by default

If waveforms are generated at extremely wide pixel widths (e.g. `maxPixelWidth = 8192`), decoding pressure increases even with thumbnail decoding.

### Recommendation

Revisit `WaveformSnapshotRenderer.RenderOptions.detailAdaptive(...)` and the HEIC generator path:
- For assets intended primarily for list + overview, prefer smaller `maxPixelWidth` (e.g. 4096).
- Consider generating two assets (LOD levels):
  - `audioSourceId.vX.thumb.heic` (low width, fast)
  - `audioSourceId.vX.detail.heic` (higher width, for editors)

Then select by use case.

## F) Memory budgeting + instrumentation (make this repeatable)

Add explicit budgets and telemetry so regressions show up quickly:

- Budgets:
  - `WaveformThumbnailCache` total cost limit
  - clip waveform caches (already exist) per-worker limits
  - any windowed snapshot caches
- Signposts:
  - decode thumbnail time + requested pixel size
  - cache hit rate (debug-only counters)
  - number of in-flight tasks
  - Metal renderer draw rate (already partially present via FPS tracker)

### How to validate

Use Instruments:
- **Allocations + VM Tracker**: scroll a track list with many rows expanded; verify resident size doesn’t climb linearly with number of visible waveforms.
- **Metal System Trace**: verify drawable/texture sizes are reasonable; ensure MSAA isn’t on by default unless desired.
- **Energy Log**: verify waveform screens idle near-zero CPU/GPU when not recording or interacting.
