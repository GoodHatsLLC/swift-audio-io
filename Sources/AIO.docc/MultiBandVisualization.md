# Multi-Band Visualization

Multi-band visualization splits mono float samples into perceptual frequency bands and
stores min, max, and RMS values at a configurable level of detail.

## Quick Start

```swift
import AIOEngine

let visualization = AudioVisualizationEngine()
let subscription = visualization.subscribe(
  request: VisualizationRequest(
    work: VisualizationWork(
      lod: LODWork(
        configuration: MultiBandLODConfiguration(
          bandCount: 5,
          lodRatio: 128,
          bufferSeconds: 300,
          sampleRate: 48_000
        ),
        publishRateHz: 60
      )
    ),
    eventMask: [.lodSnapshot]
  )
) { event in
  guard case .lodSnapshot = event else { return }
  _ = visualization.withCurrentLODSnapshotRef { snapshot in
    snapshot.bandCount
  }
}

visualization.startVisualization()
subscription.cancel()
```

## Configuration

``MultiBandLODConfiguration`` controls allocation and band splitting:

- `bandCount`: 1...128 frequency bands. 5 is the default.
- `lodRatio`: raw samples per LOD bucket. 128 is the default.
- `bufferSeconds`: rolling live buffer duration when `rawBufferLengthOverride` is not set.
- `sampleRate`: nominal source sample rate.
- `crossoverMode`: mel, linear, or custom crossover frequencies.
- `snapshotSwapInterval`: how often the live processor swaps published buffer slots.
- `rawBufferLengthOverride`: exact raw-sample length for offline/file extraction.

Use `init(validatingBandCount:...)` to reject invalid user input, or the non-throwing
initializer when clamping is acceptable.

## Processor

``MultiBandLODProcessor`` is the low-level processor:

```swift
let processor = MultiBandLODProcessor(
  configuration: MultiBandLODConfiguration(sampleRate: 48_000)
)

let samples: [Float] = [0, 0.2, -0.1, 0.4]
processor.process(samples)

let copiedSnapshot = processor.snapshot()
let liveRef = processor.snapshotRef()
```

For live rendering, prefer ``LODSnapshotRef`` or
``MultiBandLODProcessor/withCurrentLODSnapshotRef(_:)``. For storage or tests, use the copied
``MultiBandLODSnapshot``.

## Snapshot Layout

Each snapshot stores band-contiguous channels:

```swift
let minValues = snapshot.copyContiguousLODChannel(.min)
let maxValues = snapshot.copyContiguousLODChannel(.max)
let rmsValues = snapshot.copyContiguousLODChannel(.rms)
```

For band `b` and LOD index `i`, the flat offset is:

```swift
let offset = (b * snapshot.lodBufferLength) + i
```

`writeIndex` means:

- Live snapshot: circular head in `0..<lodBufferLength`.
- Offline snapshot: count of written LOD buckets.

## Offline Extraction

Use ``OfflineLODExtractor`` to build a snapshot from an audio file:

```swift
let extractor = OfflineLODExtractor(
  configuration: MultiBandLODConfiguration(
    bandCount: 5,
    lodRatio: 128,
    bufferSeconds: 1,
    sampleRate: 48_000
  ),
  channelStrategy: .average
)

let result = try await extractor.extract(from: audioURL)
let snapshot = result.snapshot
```

The extractor sizes the snapshot from the file's frame count, not from a live rolling-window
duration.

## Renderer Contract

AIO does not ship a public renderer. Renderers should consume the public snapshot contract:

- `bandCount`
- `lodRatio`
- `rawBufferLength`
- `lodBufferLength`
- `writeIndex`
- per-band min/max/RMS buffers

Renderers that need direct buffer access should prefer `withContiguousLODChannel` and the
checked `withContiguousLODChannelIfValid` variants rather than copying every frame.

## Topics

### Configuration

- ``MultiBandLODConfiguration``
- ``CrossoverMode``

### Data

- ``MultiBandLODSnapshot``
- ``BandLODData``
- ``LODChannel``
- ``LODSnapshotRef``

### Processing

- ``MultiBandLODProcessor``
- ``OfflineLODExtractor``
- ``AudioVisualizationEngine``
