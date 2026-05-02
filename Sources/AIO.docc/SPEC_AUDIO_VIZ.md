# Audio Visualization Spec

AIO visualization converts realtime or file-backed audio samples into data structures that
renderers can consume without depending on an app-specific UI layer.

## Scope

This document covers the public AIO surface:

- ``AudioVisualizationEngine``
- ``VisualizationRequest`` and ``VisualizationEvent``
- ``MultiBandLODProcessor``
- ``MultiBandLODConfiguration``
- ``MultiBandLODSnapshot`` and ``LODSnapshotRef``
- ``OfflineLODExtractor``

Rendering is consumer-owned. AIO provides stable sample, timing, and LOD data contracts; it
does not require a specific SwiftUI, Metal, or image renderer.

## Live Pipeline

1. A recorder installs an `AIOEngine` tap through `startRecording(configuration:)`.
2. The tap converts input audio into the configured processing format.
3. The engine writes converted samples into per-channel ring buffers for file output.
4. The engine forwards channel-zero float samples to each attached `BufferReceiver<Float>`.
5. ``AudioVisualizationEngine`` consumes those buffers and publishes visualization events to
   active subscribers.

Receiver subscriptions are token-scoped:

```swift
let visualization = AudioVisualizationEngine()
let token = await engine.attachBufferReceiver(visualization)
defer { token.invalidate() }
```

## Subscriber Demand

`AudioVisualizationEngine` computes active work from subscriber demand. If no subscriber
requests LOD or analysis work, the processor avoids that work.

```swift
let subscription = visualization.subscribe(
  request: VisualizationRequest(
    work: VisualizationWork(
      lod: LODWork(configuration: .default, publishRateHz: 60),
      analysis: AnalysisWork(updateRateHz: 30, timeDomain: .realTime)
    ),
    eventMask: [.lodSnapshot, .timeDomain]
  )
) { event in
  // Handle only the requested event kinds.
}
```

Cancel the subscription when the consumer no longer needs updates.

## LOD Data Contract

The LOD pipeline stores three channels per frequency band:

- `min`: lowest sample value in the LOD window.
- `max`: highest sample value in the LOD window.
- `rms`: root-mean-square energy for the LOD window.

Key values:

- `rawBufferLength`: number of raw samples represented by the snapshot.
- `lodRatio`: raw samples per LOD bucket.
- `lodBufferLength`: `ceil(rawBufferLength / lodRatio)`.
- `writeIndex`: live ring-buffer head for live data, monotonic written-bucket count for
  offline data.

See <doc:MultiBandLODContract> for CPU and renderer indexing rules.

## Live Snapshots

Use frame-scoped zero-copy access for render loops:

```swift
visualization.withCurrentLODSnapshotRef { snapshot in
  for band in 0..<snapshot.bandCount {
    snapshot.withMinBuffer(band: band) { values in
      _ = values.count
    }
  }
}
```

Do not cache an ``LODSnapshotRef`` across frames. It references triple-buffered storage whose
role can change after publication.

## Offline Snapshots

Use ``OfflineLODExtractor`` for files:

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

Offline extraction uses `rawBufferLengthOverride` internally so the snapshot aligns to the
file frame count plus one LOD pad. This keeps `writeIndex` monotonic and avoids treating a
file snapshot as a wrapping live ring.

## Realtime Rules

`processBuffer(_:timing:)` runs on the realtime audio path. Receivers must:

- Avoid blocking calls, locks with unknown contention, and async hops.
- Avoid per-buffer allocation.
- Copy only when crossing into non-realtime consumers.
- Treat `BufferTiming.sampleTime` as the receiver-domain sample time.

## Public Validation

Visualization configuration types accept user-controlled values. Use throwing validation
initializers when a caller wants an error, or non-throwing/clamping initializers when a safe
fallback is acceptable. Public initializer failures should be normal Swift errors, not
process exits.
