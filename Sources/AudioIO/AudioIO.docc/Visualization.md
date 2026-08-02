# Visualization

Real-time analysis (time domain, frequency domain, beat detection) and multi-band LOD waveform data for GPU rendering. Rendering itself is consumer-owned — AudioIO provides the data contracts.

## The engine

``AudioVisualizationEngine`` consumes audio buffers from any ``BufferReceiver`` source — most commonly the recording tap — and publishes visualization events to active subscribers.

```swift
let visualization = AudioVisualizationEngine(
  configuration: .init(sampleRate: 48_000),
)
let receiverToken = await engine.attachBufferReceiver(visualization)
defer { receiverToken.invalidate() }
```

The visualization engine is a `BufferReceiver<Float>` itself, so it slots into the same token-scoped attachment model as any other receiver.

## Subscriber demand

What computation runs is determined by the union of active subscribers' requests:

```swift
let subscription = visualization.subscribe(
  request: VisualizationRequest(
    work: VisualizationWork(
      lod: LODWork(configuration: .default, publishRateHz: 60),
      analysis: AnalysisWork(
        updateRateHz: 30,
        timeDomain: .realTime,
      ),
    ),
    eventMask: [.lodSnapshot, .timeDomain],
  ),
) { event in
  // Handle only the requested event kinds.
}
visualization.startVisualization()

// later:
subscription.cancel()
```

If no subscriber requests LOD or analysis work, the processor avoids that work. Multiple subscribers compose: each requests the kinds of data they consume, and the engine processes the union once.

## LOD data contract

The multi-band LOD pipeline maintains a per-band ring buffer of three channels — min sample, max sample, peak sample — at a downsampled ratio. Consumers read snapshots in one of two shapes:

- ``AudioVisualizationEngine/multiBandLOD`` returns a fresh ``MultiBandLODSnapshot`` copy. Use for off-thread reads.
- ``AudioVisualizationEngine/withCurrentLODSnapshotRef(_:)`` provides frame-scoped zero-copy access via ``LODSnapshotRef``. Use from a render loop where allocation isn't acceptable.

Both shapes return `nil` when LOD work isn't enabled.

## Offline LOD extraction

For LOD data from a file (not a live stream), use ``OfflineLODExtractor``:

```swift
let extractor = OfflineLODExtractor(configuration: .default)
let result = try await extractor.extract(from: audioURL)
let snapshot = result.snapshot
```

Offline extraction is independent of the live ``AudioVisualizationEngine`` — it produces the same ``MultiBandLODSnapshot`` shape from a file with explicit channel-strategy control. ``OfflineLODExtractor`` lives in the `AudioSignals` library product and can be used standalone without recording/playback.

For long files, use the progress overload to display the waveform before the
entire file has been decoded:

```swift
let result = try await extractor.extract(from: audioURL) { progress in
  await waveformStore.update(
    snapshot: progress.snapshot,
    isComplete: progress.isComplete
  )
}
```

Each ``OfflineLODProgress/snapshot`` has a
``LODTimelineLayout/staticLinear(availableRawSampleCount:totalRawSampleCount:)``
layout. `totalRawSampleCount` fixes the full timeline immediately, while
`availableRawSampleCount` identifies the contiguous prefix ready to draw. The
handler is awaited, so updates are delivered in order and remain part of the
extraction task. Intermediate updates are time-throttled; the final update is
always delivered and matches the returned ``OfflineLODResult``. Cancelling the
extraction task stops file reads and throws
``MultiBandLODProcessor/LODGenerationError/cancelled`` without publishing a
completion update.

## Frequency analysis details

The frequency analyzer uses an FFT (``FrequencyAnalyzer``) followed by bucketing (``FrequencyBucketer``) into perceptually-weighted bands:

- ``FrequencyBucketMode`` chooses linear, log, mel, or custom band layouts.
- ``FrequencyWeighting`` applies a perceptual curve (none, A-weighting, ITU-R BS.1770).
- ``StandardBands`` exposes commonly-requested band layouts (octave, third-octave, mel-24).

Output arrives as ``FrequencyDomainData`` with smoothed magnitudes plus peak-hold values.

## Beat detection

``BeatDetector`` runs alongside frequency analysis. It exposes onset detection with configurable sensitivity and a minimum inter-beat interval:

- ``BeatDetectionConfiguration/default`` — moderate sensitivity, 150 ms minimum interval.
- ``BeatDetectionConfiguration/lowSensitivity`` — relaxed thresholds for sparse content.
- ``BeatDetectionConfiguration/highSensitivity`` — tighter thresholds for dense content.

## Topics

### Engine

- ``AudioVisualizationEngine``
- ``AudioVisualizationEngine/Configuration``
- ``VisualizationDriving``

### Subscription

- ``VisualizationRequest``
- ``VisualizationEvent``
- ``VisualizationEventMask``
- ``VisualizationSubscription``

### Work types

- ``VisualizationWork``
- ``LODWork``
- ``AnalysisWork``
- ``FrequencyDomainWork``

### LOD data

- ``MultiBandLODProcessor``
- ``MultiBandLODConfiguration``
- ``MultiBandLODSnapshot``
- ``LODSnapshotRef``
- ``LODTimelineLayout``
- ``OfflineLODExtractor``
- ``OfflineLODProgress``
- ``OfflineLODResult``

### Analyzer types

- ``AmplitudeAnalyzer``
- ``FrequencyAnalyzer``
- ``FrequencyBucketer``
- ``FrequencyBucketMode``
- ``FrequencyWeighting``
- ``StandardBands``
- ``TimeDomainData``
- ``FrequencyDomainData``
- ``BeatInfo``
- ``BeatDetectionConfiguration``
- ``BeatDetector``
