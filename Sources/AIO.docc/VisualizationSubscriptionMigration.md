# Visualization API Migration Guide

## Summary

The visualization API is now event-first and strict about configuration inputs:

- `VisualizationSinks` has been removed.
- `AudioVisualizationEngine.subscribe(request:handler:)` is the primary subscription API.
- `MultiBandLODProcessor.generateFromFile(...)` has been removed; use `OfflineLODExtractor`.
- Configuration types now provide:
  - strict initializers (no silent clamping),
  - `validating...` throwing initializers,
  - clearly-labeled `clamping...` initializers.

## Subscription Migration

### Before

```swift
let subscription = engine.subscribe(
  request: request,
  sinks: VisualizationSinks(
    timeDomain: { data in handleTime(data) },
    lodSnapshot: { snapshot in render(snapshot) }
  )
)
```

### After

```swift
let subscription = engine.subscribe(request: request) { event in
  switch event {
  case .timeDomain(let data):
    handleTime(data)
  case .lodSnapshot:
    engine.withCurrentLODSnapshotRef { snapshot in
      render(snapshot)
    }
  default:
    break
  }
}
```

## Offline LOD Migration

### Before

```swift
let snapshot = try await MultiBandLODProcessor.generateFromFile(
  url: audioURL,
  configuration: .default
)
```

### After

```swift
let extractor = OfflineLODExtractor(
  configuration: .default,
  channelStrategy: .average
)
let snapshot = try await extractor.extract(from: audioURL).snapshot
```

## Configuration Migration

### Strict initializer (default)

```swift
let config = MultiBandLODConfiguration(
  bandCount: 5,
  lodRatio: 128,
  bufferSeconds: 300,
  sampleRate: 44_100
)
```

### Throwing validation for untrusted input

```swift
let config = try MultiBandLODConfiguration(
  validatingBandCount: userBandCount,
  lodRatio: userLodRatio,
  bufferSeconds: userBufferSeconds,
  sampleRate: userSampleRate
)
```

### Explicit clamping for permissive behavior

```swift
let config = MultiBandLODConfiguration(
  clamping: userBandCount,
  lodRatio: userLodRatio,
  bufferSeconds: userBufferSeconds,
  sampleRate: userSampleRate
)
```
