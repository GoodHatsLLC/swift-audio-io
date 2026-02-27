# SPEC: Audio Visualization (AIO → Recorder)

**Status**: Implemented  
**Last Updated**: 2026-01-13  
**Primary Owners**: `Packages/AIO` (signal → LOD), `Packages/AppLibrary` (rendering + UX)

## Scope

This spec describes the audio visualization system as implemented today:

- **Producer (AIO)**: Captures live audio buffers and produces visualization data, primarily **multi-band Level-of-Detail (LOD)** waveform buffers suitable for Metal rendering.
- **Consumers (Recorder / AppLibrary)**:
  - Live recording waveform via `WaveformProviding.liveRecordingView` (Metal pipeline uses `MetalWaveformView` + `LODSnapshotRef`; Beat pipeline uses `BeatLiveWaveformView` + beat analysis).
  - Static/offline waveforms and thumbnails via `WaveformMetal` (`WaveformSnapshotRenderer` + HEIC assets) or `WaveformLightweight` (sample-based rendering).
  - Mini waveform via `WaveformProviding.miniLiveView` (pipeline-specific implementation).
  - Track detail playback waveform via `WaveformProviding.trackPlaybackView` (Metal pipeline uses HEIC fallback + LOD snapshot, lightweight uses samples).

This spec does **not** cover:

- Audio recording file formats or encoding.
- Project mixing/export.
- Widgets’ decorative waveform (pure SwiftUI; not AIO-driven).

## Key Concepts / Terminology

- **Raw samples**: Float PCM samples normalized to `[-1, 1]`.
- **LOD ratio**: `lodRatio` raw samples collapse into one LOD “bucket”.
- **Band**: One frequency range produced by a cascading lowpass filter bank (mel/linear/custom crossovers).
- **LOD buffers**: For each band and LOD index:
  - `min` (lowest sample in the bucket)
  - `max` (highest sample in the bucket)
  - `rms` (energy in the bucket)
- **Live snapshot**: `LODSnapshotRef` (zero-copy view into preallocated triple-buffered storage).
- **Static snapshot**: `MultiBandLODSnapshot` (copying, owned arrays; used for file-backed and cached cases).
- **AudioSource metadata**: Offline waveform generation uses `AudioSource` fields (`durationSeconds`, `sampleRateHz`, `url`) and is keyed by `audio_source.id`.
- **AudioSegment range**: Segment-based views (editor + clip thumbnails) use `AudioSegment` ranges for cropping and cache keys.

## Component Overview

### 1) `AIOEngine` (buffer capture + emission)

`AIOEngine` records via an input-node tap and converts audio to a processing format before fan-out:

- Input tap (AVAudioEngine): `AIOEngine.warm(...)` installs a tap on `engine.inputNode`.
- Buffer conversion: the tap buffer is converted into `processingFormat` via a cached `AVAudioConverter`.
- Ring buffers: converted samples are written into `RingBuffer<Float>` per channel for file writing.
- Visualization fan-out: for **channel 0 only**, AIO calls each attached `BufferReceiver<Float>` with:
  - `UnsafeBufferPointer<Float>` pointing to the converted channel-0 samples
  - `BufferTiming` that tracks monotonic sample time in the receiver domain

**Important**: the visualization feed is **post-conversion** and is **channel 0 only**.

#### Playback state

`AIOEngine` exposes playback state for UI via `playback: Playback?`, updated on a **coarse timer** (default ~0.5s, configurable via `defaultPlaybackPollingInterval` and per-playback overrides) to avoid excessive observation churn.

### 2) `BufferReceiver` + `BufferTiming` (real-time boundary)

`BufferReceiver<T>` is the abstraction between the audio tap thread and downstream processors:

- `processBuffer(_:)` and `processBuffer(_:timing:)` are invoked on a **real-time audio thread**.
- Implementations must be **fast, non-blocking**, and avoid allocations when possible.
- `endBufferTask()` signals teardown when the emitter detaches receivers.

`BufferTiming` provides:

- `sampleTime` + `sampleRate` in the **receiver’s** sample domain.
- Optional upstream tap timing (`hostTime`, `sourceSampleTime`, `sourceSampleRate`) when available.

### 3) `AudioVisualizationEngine` (AIO’s live visualization hub)

`AudioVisualizationEngine` lives in AIO (`Packages/AIO/Sources/AIOEngine/Visualization/AudioVisualizationEngine.swift`) and is:

- `@Observable` for SwiftUI-friendly state
- a `BufferReceiver<Float>` for live tap consumption
- `@unchecked Sendable` because it crosses concurrency boundaries and is called from the audio thread

It has two broad responsibilities:

1) **(Primary) Multi-band LOD pipeline** for waveform rendering
2) **(Secondary) Time/frequency/beat analysis** for classic meters and spectrum views

#### 3.1 Multi-band LOD (used by Recorder in production)

`AudioVisualizationEngine` can host an optional `MultiBandLODProcessor`:

- Configure via `VisualizationRequest(work: VisualizationWork(lod: ...))` on active subscriptions.
  - LOD processing is enabled only when at least one active subscription requests LOD and provides an LOD sink.
- Read:
  - `withCurrentLODSnapshotRef(_:) -> R?` (preferred; frame-scoped zero-copy)
  - `multiBandLOD: MultiBandLODSnapshot?` (copying; avoid per-frame)

The LOD processor runs from `processBuffer(_:timing:)` and is fed the raw float samples.

#### 3.2 Time/frequency/beat

`AudioVisualizationEngine` also exposes:

- `timeDomain: TimeDomainData` (includes `samples`, `peaks`, `rmsLevel`, `level`)
- `frequencyDomain: FrequencyDomainData` (includes bucketed spectrum, centroid, etc.)
- `beat: BeatInfo`

Analysis work is declared by active subscriptions through `VisualizationRequest.work.analysis` and emitted only when corresponding sinks are present.

### 4) `MultiBandLODProcessor` (AIO’s LOD generator)

`MultiBandLODProcessor` is the core producer of waveform visualization buffers:

- Splits samples into bands with a **cascading lowpass filter bank**.
- Accumulates per-band running stats for each LOD window:
  - `minV`, `maxV`, and `sumSq` for RMS.
- Commits 1 LOD bucket every `lodRatio` samples.
- Stores committed buckets into **triple-buffered** circular storage:
  - 3 preallocated slots rotate through write/current/retiring roles.
  - Snapshot publication is an atomic swap (`ManagedAtomic<Int>`).

Offline generation is supported via:

- `static func generateFromFile(url:configuration:) async throws -> MultiBandLODSnapshot`
  - Reads the file in chunks, averages channels for multi-channel content, and returns a static snapshot sized to the file’s exact frame count (via `rawBufferLengthOverride` padding).

## Data Model and Layout

### LOD Snapshot interface

Both live and static snapshots conform to `LODSnapshot`:

- `bandCount`
- `writeIndex`
- `lodRatio`
- `rawBufferLength`
- `lodBufferLength`
- `withContiguousLODChannel(band:channel:_:)`
- `copyContiguousLODChannel(_:)` (allocating)

### Buffer semantics

- **Live recording**:
  - LOD buffers are circular; `writeIndex` wraps at `lodBufferLength`.
  - `rawBufferLength` is sized for a rolling window (`sampleRate * bufferSeconds`).
  - Consumers should interpret `writeIndex` as “current head” in a ring.
- **Offline snapshots**:
  - `rawBufferLengthOverride` is used so the snapshot aligns to the file frame count (with padding to allow the final partial LOD commit).
  - `writeIndex` is treated as monotonic “number of LOD buckets written” (the code paths try to avoid wrap for offline).

### Memory sizing (order-of-magnitude)

The LOD processor’s core storage is:

```
3 slots * bandCount * lodBufferLength * 3 buffers (min/max/rms) * sizeof(Float)
```

Where `lodBufferLength = ceil(rawBufferLength / lodRatio)`.

## Live Recording Pipeline (Recorder)

### Setup sequence

The Recorder app wires live visualization when a recording successfully starts:

1) Create `AudioVisualizationEngine` with low-power configuration and the negotiated input sample rate:
   - `AudioVisualizationEngine(configuration: .lowPower.withSampleRate(inputConfig.sampleRate.platform))`
2) Create and store visualization state with declared visualization work:
   - `LiveVisualizationState(engine: visualizationEngine, work: VisualizationWork(lod: ...))`
3) Attach as a buffer receiver to `AIOEngine`:
   - `await engine.attachBufferReceiver(visualizationEngine)`
4) Start the visualization engine:
   - `visualizationEngine.startVisualization()`

The in-progress model stores the engine:

- `InProgressRecording.visualizationEngine = visualizationEngine`
- Recording duration prefers the visualization clock (`currentTimeSeconds`) when available.

### UI consumption

The main live waveform uses Metal rendering:

- `RecordingView` resolves the active provider and renders `WaveformProviding.liveRecordingView`.
  - Metal pipeline uses a frame-scoped `LODSnapshotRef` from `visualizationEngine.withCurrentLODSnapshotRef { ... }`.
  - Beat pipeline uses `BeatLiveWaveformView` with beat detection configured.
- View visibility is forwarded through `LiveVisualizationState`:
  - `viewDidAppear()` creates a subscription
  - `viewDidDisappear()` cancels the subscription

### Lifecycle gating

Recorder routes scene phase to the visualization engine:

- Foreground active: `resumeVisualization()` (only if recording)
- Background/inactive: `pauseVisualization()`

`pauseVisualization()` stops per-buffer processing without resetting LOD history.

### Audio-thread contract

End-to-end constraints for live mode:

- `AIOEngine` calls `processBuffer(_:timing:)` on the real-time audio thread.
- `AudioVisualizationEngine.processBuffer` must remain fast and non-blocking.
- Snapshot reads must be frame-scoped; `LODSnapshotRef` must not be cached across frames.

## Offline / Static Waveform Pipelines (Recorder)

### Full-track LOD for detail views

For track detail playback UI, the Metal pipeline generates an offline multi-band snapshot:

- Resolve the `AudioSource` (URL + cached duration/sample rate) from DB.
- Choose `lodRatio` via `WaveformLODHeuristics.recommendedOfflineLodRatio(fileFrameCount:)`.
- Call `MultiBandLODProcessor.generateFromFile(url:configuration:)`.
- Render with `MetalTrackPlaybackWaveformView` / `MetalWaveformView` using a static snapshot provider.

**Detail view UX implementation details:**

- `DetailPlayerView` renders `WaveformProviding.trackPlaybackView`; the Metal provider uses a pre-rendered HEIC image (`TrackWaveformView`) as a fast fallback before showing the LOD snapshot.
- Both waveform implementations remain pannable + zoomable for exploration and are not playback-following.

This is used in:

- Track detail waveform (`DetailPlayerView`)
  - The segment editor waveform is currently a static render and does not use the presentation clock.

### Clip thumbnails (timeline)

Clip thumbnails use a two-tier strategy (Metal pipeline):

1) Prefer **HEIC crop** from a precomputed static waveform asset (fast, minimal CPU).
2) If needed, compute a **time-range LOD snapshot** and render it to an image:
   - Read a time window from the file (`AVAudioFile.framePosition`).
   - Feed samples into `MultiBandLODProcessor`.
   - `finalize()` to commit a partial last LOD window.
   - Render using `WaveformSnapshotRenderer`.

Clip thumbnails and intermediate caches are keyed by `audio_source.id` plus the `AudioSegment` range.

Concurrency is controlled by a pooled renderer worker actor with caching for both rendered images and intermediate snapshots.

## Rendering Notes (AppLibrary)

### `MetalWaveformView` (static vs live)

`MetalWaveformView` accepts either:

- `LODSnapshotRef` (live ring-buffer snapshot; data changes over time), or
- `MultiBandLODSnapshot` (static offline snapshot; data is immutable).

Rendering policy:

- For **live snapshots**, the renderer uploads LOD buffers every frame and may apply live-scroll smoothing.
- For **static snapshots**, the renderer uploads waveform buffers once per snapshot and then reuses GPU buffers while updating uniforms every frame (useful when `smoothOffsetChanges` is enabled for playback-following).

## Known Intentional Asymmetries / Caveats

- **Channel handling differs**:
  - Live visualization (AIO tap feed) uses **channel 0 only**.
  - Offline generation (`generateFromFile` and clip thumbnail LOD) averages channels to mono for multi-channel files.
- **Non-DEBUG builds don’t update `timeDomain`/`frequencyDomain`/`beat`**:
  - UI that depends on `amplitudeData` will show a “silent” visualization unless compiled with `DEBUG` or the implementation changes.
- **Playback observation is intentionally coarse**:
  - `AIOEngine.playback` is refreshed at ~0.5s cadence.

## Implementation References (Source of Truth)

**AIO**

- `Packages/AIO/Sources/AIOEngine/AIOEngine.swift` (tap install, conversion, buffer receiver fan-out)
- `Packages/AIO/Sources/Tools/BufferReceiver.swift` (`BufferReceiver`, `BufferTiming`)
- `Packages/AIO/Sources/AIOEngine/Visualization/AudioVisualizationEngine.swift` (live engine, LOD integration, consumer gating)
- `Packages/AIO/Sources/AIOEngine/Visualization/MultiBandLODTypes.swift` (LOD types, `MultiBandLODSnapshot`, `LODSnapshot`)
- `Packages/AIO/Sources/AIOEngine/Visualization/MultiBandLODProcessor.swift` (triple-buffered LOD generation, offline file generation)
- `Packages/AIO/Sources/AIO.docc/MultiBandVisualization.md` (API documentation and usage notes)

**Recorder / AppLibrary**

- `Packages/AppLibrary/Sources/AppTarget/Recording/RecordingService.swift` (creates/attaches/starts visualization engine; scene phase gating)
- `Packages/AppLibrary/Sources/AppTarget/Database/InProgressRecording.swift` (duration uses visualization clock when available)
- `Packages/AppLibrary/Sources/AppTarget/RecordingView.swift` (live waveform wiring through provider)
- `Packages/AppLibrary/Sources/AppTarget/PipelineWaveformViews.swift` (pipeline wrappers for track/clip views)
- `Packages/AppLibrary/Sources/WaveformInterface/WaveformProviding.swift` (provider protocol, contexts, registry)
- `Packages/AppLibrary/Sources/WaveformInterface/WaveformPipeline.swift` (pipeline enum)
- `Packages/AppLibrary/Sources/WaveformInterface/TrackWaveformView.swift` (shared HEIC waveform view)
- `Packages/AppLibrary/Sources/WaveformInterface/WaveformPlaybackGeometry.swift` (shared playhead/offset/scrub math)
- `Packages/AppLibrary/Sources/WaveformMetal/MetalWaveformView.swift` (Metal renderer; supports live `LODSnapshotRef` + static `MultiBandLODSnapshot`)
- `Packages/AppLibrary/Sources/WaveformMetal/MetalTrackPlaybackWaveformView.swift` (playback-following wrapper)
- `Packages/AppLibrary/Sources/WaveformMetal/MetalTrackWaveformView.swift` (pan + zoom wrapper)
- `Packages/AppLibrary/Sources/WaveformMetal/WaveformSnapshotRenderer.swift` (offline render to `CGImage`)
- `Packages/AppLibrary/Sources/WaveformMetal/WaveformLODHeuristics.swift` (offline LOD ratio heuristic)
- `Packages/AppLibrary/Sources/WaveformMetal/MetalClipWaveformThumbnailView.swift` (HEIC crop vs LOD range render strategy)
- `Packages/AppLibrary/Sources/WaveformLightweight/LightweightWaveformView.swift` (sample-based waveform rendering)
- `Packages/AppLibrary/Sources/WaveformBeat/BeatLiveWaveformView.swift` (beat-detection live waveform)
