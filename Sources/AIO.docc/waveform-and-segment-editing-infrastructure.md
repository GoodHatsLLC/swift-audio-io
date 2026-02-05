# Waveform + Segment Editing Infrastructure (Detail View + Segment Editor)

This document describes the **new infrastructure and contracts** behind:

- The **large, draggable Metal waveform** on the track detail view
- The **segment editor** reordering behavior (within a track)

It focuses on *data contracts* (what values mean), *why prior behavior looked wrong*, and *how to extend this safely*.

---

## 1) Waveform Architecture (Pipelines + Surfaces)

Waveforms are now modular: AppTarget only talks to `WaveformProviding` (from
`Packages/AppLibrary/Sources/WaveformInterface/`) and resolves concrete implementations via
`WaveformProviderRegistry` (built in `WaveformProviders/`).

Each pipeline implements the same surface set (live, mini, track, playback, segment edit, clip
thumbnail). The three concrete pipelines are:

1. **Metal pipeline** (`WaveformMetal/`)  
   Uses pre-rendered HEIC assets for cheap list/thumbnail rendering and Metal LOD for detail views.
   Key files:
   - Snapshot generation: `Packages/AIO/Sources/AIOEngine/Visualization/MultiBandLODProcessor.swift`
   - Snapshot data types: `Packages/AIO/Sources/AIOEngine/Visualization/MultiBandLODTypes.swift`
   - Metal view: `Packages/AppLibrary/Sources/WaveformMetal/MetalWaveformView.swift`
   - Detail wrapper (playback-follow + scrub): `Packages/AppLibrary/Sources/WaveformMetal/MetalTrackPlaybackWaveformView.swift`
   - HEIC view: `Packages/AppLibrary/Sources/WaveformMetal/MetalWaveformImageView.swift`
   - Clip thumbnails: `Packages/AppLibrary/Sources/WaveformMetal/MetalClipWaveformThumbnailView.swift`
   - Shader contract: `Packages/AppLibrary/Sources/WaveformMetal/Resources/viz.metal`

2. **Lightweight pipeline** (`WaveformLightweight/`)  
   Sample-based waveform rendering for low-cost surfaces.
   Key files:
   - `Packages/AppLibrary/Sources/WaveformLightweight/LightweightWaveformView.swift`
   - `Packages/AppLibrary/Sources/WaveformLightweight/LightweightTrackPlaybackWaveformView.swift`

3. **Beat pipeline** (`WaveformBeat/`)  
   Live waveform with beat detection, with lightweight fallback for static surfaces.
   Key file: `Packages/AppLibrary/Sources/WaveformBeat/BeatLiveWaveformView.swift`

AppTarget uses `PipelineTrackWaveformView` / `PipelineClipWaveformThumbnailView` wrappers to resolve
the active pipeline from settings and render via the interface.

---

## 2) The LOD Contract (What the Shader + CPU Agree On)

The Metal shader (`viz.metal`) expects a **per-band circular buffer** of LOD values:

- `lodMin[band][i]` — min amplitude in LOD window `i`
- `lodMax[band][i]` — max amplitude in LOD window `i`
- `lodRMS[band][i]` — RMS amplitude in LOD window `i`

The CPU produces this with `MultiBandLODProcessor`, which filters audio into bands and commits one LOD sample per `lodRatio` raw samples.

### Key values

These values are carried to the shader through `Uniforms`:

- `rawBufferLength` (“bufferLength” in `viz.metal`)  
  Number of **raw samples** represented by the snapshot.

- `lodRatio`  
  Number of raw samples aggregated into a single LOD bucket.

- `lodBufferLength` (“lodLength” in `viz.metal`)  
  Number of **LOD buckets per band** allocated on CPU and used in shader addressing.
  Contract:  
  `lodBufferLength = ceil(rawBufferLength / lodRatio)`

- `writeIndex`  
  The “head” position of the circular buffer:
  - In **live mode**, it wraps continuously (`0..<lodBufferLength`).
  - In **offline mode (file)**, we intentionally size the buffers so `writeIndex` *does not wrap* and behaves as a monotonic “length written”.

### Why “chunking” could happen even when zoomed in

Two separate issues can produce “chunky” output:

1. **Rendering at 1× scale and being upscaled**  
   If `MTKView.drawableSize` is effectively in points instead of pixels, the GPU renders fewer columns than the screen has pixels, and the system scales the result → visible stepping/pixelation.

2. **Offline LOD sized to a large, mostly-empty buffer**  
   If offline snapshots are sized to a 5-minute default buffer (or rounded seconds) rather than the actual file frames, panning can expose large regions of “empty” or repeated data, and zooming can feel wrong because the visible region is dominated by padding rather than audio.

This infrastructure change addresses both.

---

## 3) Offline Snapshot Generation (File → LOD Snapshot)

### The problem we’re fixing

Historically, offline generation could be inadvertently sized like a live ring buffer:

- `rawBufferLength = sampleRate * bufferSeconds` (rounded to whole seconds, often much larger than the file)
- `writeIndex` would wrap if the file produced more LOD commits than `lodBufferLength`
- the renderer could pan into regions that did not correspond to real audio, causing “repeat the last visible sample” artifacts

### The new approach

We add a configuration knob:

- `MultiBandLODConfiguration.rawBufferLengthOverride`  
  File: `Packages/AIO/Sources/AIOEngine/Visualization/MultiBandLODTypes.swift`

When present, `rawBufferLength` is driven by this override instead of `sampleRate * bufferSeconds`.

`MultiBandLODProcessor.generateFromFile(...)` now:

1. Reads the file length in frames (`file.length`)
2. Sets:
   - `rawBufferLengthOverride = fileFrameCount + lodRatio`
3. Processes the file in chunks
4. After the loop, commits one final LOD bucket if there is a partial window pending

File: `Packages/AIO/Sources/AIOEngine/Visualization/MultiBandLODProcessor.swift`

### Why `+ lodRatio` matters

We want offline `writeIndex` to behave like a monotonic “how many LOD buckets were written”, not like a live wrapping head pointer.

Let:

- `N = fileFrameCount`
- `R = lodRatio`
- `W = ceil(N / R)` — number of LOD buckets needed to represent the file (including the final partial bucket)

If we set:

- `rawBufferLengthOverride = N + R`

Then:

- `lodBufferLength = ceil((N + R) / R) = ceil(N / R) + 1 = W + 1`

So the offline processor can write `W` buckets and `writeIndex == W` without wrapping.

This yields two important invariants for offline snapshots:

- `0 < writeIndex < lodBufferLength`
- `writeIndex == ceil(fileFrameCount / lodRatio)`

That makes downstream logic (width calculation, bounds clamping, timeline mapping) far more reliable.

---

## 4) Zoom + Offset Semantics (Detail Waveform)

The `viz.metal` shader maps pixels to LOD samples like this (simplified):

- `visibleLODSamples = lodBufferLength / (zoom * 2.0)`
- `lodSamplesPerPixel = visibleLODSamples / screenWidth`
- `lodOffset = viewOffset / lodRatio`  (note: `viewOffset` is in raw samples)

Important consequence:

- **`zoom = 1.0` shows half the buffer** (because of the `/ 2.0` term)
- **`zoom = 0.5` shows the full buffer**

This is why the static renderer uses `zoom = 0.5` for “full track” images, and why the detail view now clamps zoom to `>= 0.5`.

### Offset meaning

- `viewOffset` is expressed in **raw samples** (not seconds).
- In the shader, offset is applied as “how many samples ago from the right edge”.
  - `viewOffset = 0` → right edge corresponds to the newest end of the buffer
  - increasing `viewOffset` pans left into older samples

### New UI clamping

The detail view now clamps pan/zoom so you can’t pan into invalid space:

- `visibleSamples = rawBufferLength / (zoom * 2.0)`
- `maxOffset = rawBufferLength - visibleSamples`
- `viewOffset ∈ [0, maxOffset]`

File: `Packages/AppLibrary/Sources/AppTarget/Detail/TrackDetailView.swift`

This addresses the “it creates infinite sound / infinite waveform of the last sample” feel by preventing the UI from requesting data outside the valid domain of the snapshot.

---

## 5) Metal Rendering Scale (Fixing “Chunky” Output)

`MTKView` renders into `drawableSize` (in pixels). In SwiftUI, it’s easy to end up rendering at point resolution and then having the compositor upscale the result.

`MetalWaveformViewRepresentable` now:

- sets `contentScaleFactor` to the device scale
- ensures `drawableSize == bounds.size * scale`

File: `Packages/AppLibrary/Sources/WaveformMetal/MetalWaveformView.swift`

This increases the vertex columns (`vertexCount = drawableWidth * 6`) to match the device pixel grid, eliminating visible stepping caused by upscaling.

---

## 6) Segment Reordering Infrastructure (Within a Track)

### The problem

The segment editor used a manual `ForEach` and attached `.onMove`, but in SwiftUI `.onMove` is only honored inside a `List` (or when a list is in edit mode).

### The new approach

`SegmentListView` now uses:

- `List { ForEach(...) }`
- `.onMove { fromOffsets, toOffset in ... }`
- `.environment(\.editMode, .constant(.active))` so reordering is always available without an Edit button.

File: `Packages/AppLibrary/Sources/AppTarget/Detail/SegmentListView.swift`

### Stable identity for editing

Reordering is very sensitive to SwiftUI identity. Using `sortOrder` as `id` breaks when you change `sortOrder` during reorder.

We introduce a computed stable ID:

- Persisted segments: `"db:\(id)"`
- New (unsaved) segments: `"tmp:<start>-<end>-<createdAt>"`

This makes drag/move operations stable and predictable during an editing session.

### Move semantics in the session

`SegmentEditSession` now implements:

- `move(fromOffsets: IndexSet, toOffset: Int)`

This matches SwiftUI list move behavior (including multi-select moves).

File: `Packages/AppLibrary/Sources/AppTarget/Detail/SegmentEditSession.swift`

---

## 7) Segment-aware overlays (Track playback + editor)

Track playback and detail waveforms must visually reflect edit decisions:

- The overlay source of truth is the `TrackEdit` sequence: ordered `TrackEditItem` rows referencing `AudioSegment` ranges.
- Enabled items render at full opacity; disabled items are visually dimmed (not removed) so users can see trimmed material.
- Gaps between enabled segments are shown as “disabled” regions when a trim sequence exists.
- When no `TrackEdit` exists, the full source range is treated as enabled (no overlay gaps).

Overlay mapping rules:

- Time mapping uses `AudioSource.durationSeconds` and `AudioSource.sampleRateHz` when available.
- Ranges are clamped to the source duration to avoid “out of bounds” overlays.
- The waveform overlay contract is exposed as `WaveformSegmentOverlay` and is shared between detail playback and segment editor surfaces.

---

## 8) What This Infrastructure Enables Next

This work intentionally moves the system toward a model that can support:

- **Multi-source editing** (segments/clips that reference different recordings)
- **Multi-lane timelines** (overlapping clips with mixing)

Key primitives you can reuse:

- Offline snapshots sized to the exact source file (so clip waveforms can be cropped reliably)
- Clip timeline waveforms that can switch from **HEIC crop** (zoomed out) to **LOD/Metal render** (zoomed in) to avoid “chunky” upscaling
- A clear “offset in raw samples” contract that is composable with a timeline mapping
- A SwiftUI drag/move foundation that behaves correctly with stable identities

For a concrete prototype plan, there is no dedicated doc yet.

---

## 9) Milestone D Prep: Clip Waveforms (Project Timeline)

Milestone C proved correctness (overlaps + export) by building a project composition. Milestone D is about making the *visual editing loop* fast and trustworthy.

### 9.1 Clip waveform “rendering ladder”

Project clips should not generate their own waveforms. Instead, they should reuse the source track’s existing representations:

1. **Zoomed out**: crop from the track’s **HEIC waveform** (cheap, stable)
2. **Zoomed in**: render from the track’s **offline LOD snapshot** via Metal (detailed, accurate)
3. **While loading**: show a placeholder (no blocking spinners during scroll)

This avoids per-clip offline processing and keeps dragging/scrolling responsive.

### 9.2 Cache key + invalidation rules

Introduce a dedicated clip-waveform cache keyed by “what the user sees”, not by clip ID:

`ClipWaveformKey` (minimum fields):

- `audioSourceId`
- `segmentId` (optional, for quick invalidation)
- `sourceStartTime`, `sourceEndTime` (from the `AudioSegment` range)
- render size: `height`, `scale`
- zoom bucket / style (if it affects output)

Cache shape:

- In-memory LRU (`NSCache`) for scroll/drag responsiveness
- Optional on-disk cache for across-launch reuse (`Library/Caches/`)

Invalidation:

- If the source waveform regenerates (HEIC or LOD snapshot), invalidate all keys for that `audioSourceId`.
- If zoom bucket changes, you may drop caches for the old bucket to cap memory.

### 9.3 Time → pixel mapping (cropping HEIC)

Cropping a clip out of a source waveform image requires a stable mapping:

- `sourceDurationSeconds` comes from `AudioSource.durationSeconds` (or loaded from asset metadata).
- Let `waveformWidthPx` be the pixel width of the full-track waveform image.
- For a clip range `[startTime, endTime]`:
  - `x0 = (startTime / sourceDurationSeconds) * waveformWidthPx`
  - `x1 = (endTime   / sourceDurationSeconds) * waveformWidthPx`

Crop `CGRect(x: x0, y: 0, width: x1 - x0, height: waveformHeightPx)`, then scale to the clip view size.

Practical notes:

- Clamp `x0/x1` to `[0, waveformWidthPx]` to avoid edge artifacts.
- Prefer pixel-aligned cropping (`floor/ceil`) to avoid shimmering under subtle scroll.

### 9.4 Time → sample mapping (Metal / LOD)

For zoomed-in rendering using the offline LOD snapshot:

- Convert times to sample indices using a consistent sample rate basis.
  - If you treat “raw samples” as file frames, prefer using `AudioSource.sampleRateHz` when available (or fallback to `AVAssetTrack`).
  - Otherwise, use the same assumptions used to build the offline snapshot.

When showing a clip window:

- Set the visible range to the clip’s duration (in samples).
- Set the view offset so the right edge aligns to the clip end time (the shader uses an “offset from right edge” model).

Important: offline snapshots may be sized to `fileFrameCount + lodRatio` (padding to keep `writeIndex` monotonic). Clip mapping should treat the “real content length” as the file length (exclude padding), otherwise the last LOD bucket can look like repeated content at the far right.

### 9.5 Rendering scale (“chunky waveform” guardrail)

If clip waveforms use Metal:

- Ensure `MTKView.drawableSize == bounds.size * deviceScale`
- Avoid point-resolution renders that get upscaled, which reintroduce the visible “chunking” artifact.

The detail waveform already enforces this; reuse that representable or keep the same scaling rules for any clip-level Metal view.

### 9.6 Current prototype status

The project UI now uses a first-pass clip waveform renderer:

- Metal clip thumbnails (HEIC crop + in-memory cache): `Packages/AppLibrary/Sources/WaveformMetal/MetalClipWaveformThumbnailView.swift`
- Currently used for clip rows in the project detail view (Milestone D starting point), and intended to be reused by the eventual timeline clip views.
- Supports a render-width cap (`maxRenderPixelWidth`) and quantized time keys to keep timeline waveforms responsive when clips become very wide.
