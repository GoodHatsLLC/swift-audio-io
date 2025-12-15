# Multi-Band Audio Visualization

Real-time multi-band waveform visualization with Level-of-Detail (LOD) processing.

## Overview

The multi-band visualization system provides frequency-separated audio data optimized for waveform rendering. It splits audio into frequency bands using a cascading lowpass filter bank and computes LOD data (min/max/RMS) suitable for efficient GPU rendering.

This system powers both live recording visualizations and static waveform snapshots.

For CPU ↔ GPU invariants (buffer layout, indexing/wrapping, zoom/offset semantics), see <doc:MultiBandLODContract>.

## Quick Start

### Live Visualization During Recording

```swift
import AIOEngine

// Get the visualization engine (typically from your audio recording setup)
let vizEngine = AudioVisualizationEngine()

// Enable multi-band LOD processing
vizEngine.enableMultiBandLOD()

// Start feeding audio data (called from your audio callback)
vizEngine.processBuffer(audioSamples)

// Access LOD snapshot for rendering (copying)
if let snapshot = vizEngine.multiBandLOD {
    // Pass to Metal renderer
    renderWaveform(snapshot)
}
```

### Offline Generation from Audio File

```swift
import AIOEngine

// Generate LOD snapshot from an audio file
let snapshot = try await MultiBandLODProcessor.generateFromFile(
    url: audioFileURL,
    configuration: .default
)

// Render to image
let renderer = try WaveformSnapshotRenderer()
let image = try renderer.render(snapshot: snapshot)
```

## Core Types

### MultiBandLODConfiguration

Configuration for the LOD processor:

```swift
let config = MultiBandLODConfiguration(
    bandCount: 5,           // Number of frequency bands (3-8)
    lodRatio: 128,          // Samples per LOD point
    bufferSeconds: 300,     // Max recording duration
    sampleRate: 44_100,     // Audio sample rate
    crossoverMode: .mel     // Frequency distribution
)
```

**Parameters:**
- `bandCount`: Number of frequency bands (3-8). More bands = finer frequency resolution.
- `lodRatio`: Downsampling ratio. 128 means every 128 samples becomes 1 LOD point with min/max/RMS.
- `bufferSeconds`: Maximum recording duration supported. Determines buffer allocation.
- `sampleRate`: Audio sample rate. Must match your audio input.
- `crossoverMode`: How frequency bands are distributed (`.mel` for perceptual, `.linear` for uniform).

**Defaults:**
```swift
MultiBandLODConfiguration.default  // 5 bands, 128 ratio, 300s, 44.1kHz, mel
```

### MultiBandLODSnapshot

Immutable snapshot of current visualization state:

```swift
struct MultiBandLODSnapshot {
    let bands: [BandLODData]     // Per-band LOD data
    let writeIndex: Int          // Current write position
    let lodRatio: Int            // Samples per LOD point
    let rawBufferLength: Int     // Total buffer capacity

    var bandCount: Int           // Number of bands
    var lodBufferLength: Int     // LOD buffer length per band
}
```

**Accessing Band Data:**
```swift
let snapshot = processor.snapshot()

// Per-band access
for band in snapshot.bands {
    let minValues = band.min   // [Float] - minimum per LOD point
    let maxValues = band.max   // [Float] - maximum per LOD point
    let rmsValues = band.rms   // [Float] - RMS energy per LOD point
}

// Flat buffers for GPU (band-contiguous)
let flatMin = snapshot.flatMinBuffer()  // [band0...][band1...]...
let flatMax = snapshot.flatMaxBuffer()
let flatRMS = snapshot.flatRMSBuffer()
```

### BandLODData

Per-band Level-of-Detail data:

```swift
struct BandLODData {
    let bandIndex: Int
    let min: [Float]    // Minimum amplitude per LOD point
    let max: [Float]    // Maximum amplitude per LOD point
    let rms: [Float]    // RMS energy per LOD point
}
```

## MultiBandLODProcessor

The main processing class that splits audio into bands and computes LOD:

```swift
let processor = MultiBandLODProcessor(configuration: .default)

// Feed audio samples (real-time)
processor.process(audioBuffer)

// Get current state
let snapshot = processor.snapshot()

// Reset for new recording
processor.reset()
```

**Thread Safety:**
- `process()` and `snapshot()` are thread-safe
- Typically called from audio thread (`process`) and main thread (`snapshot`)

## Integration with AudioVisualizationEngine

The `AudioVisualizationEngine` provides convenient integration:

```swift
@MainActor
final class AudioVisualizationEngine {
    // Enable/disable multi-band processing
    func enableMultiBandLOD(configuration: MultiBandLODConfiguration = .default)
    func disableMultiBandLOD()
    func resetMultiBandLOD()

    // Access current state
    var multiBandLOD: MultiBandLODSnapshot?
    var isMultiBandLODEnabled: Bool

    // Feed audio (called from processBuffer)
    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>)
}
```

**Usage in Recording Pipeline:**
```swift
// During recording setup
vizEngine.enableMultiBandLOD()

// In audio callback
func audioCallback(samples: UnsafeBufferPointer<Float>) {
    vizEngine.processBuffer(samples)
}

// In UI (SwiftUI timer or display link)
struct WaveformView: View {
    @State private var snapshot: MultiBandLODSnapshot?

    var body: some View {
        // Render waveform using snapshot
    }

    func updateSnapshot() {
        snapshot = vizEngine.multiBandLOD
    }
}
```

## Offline File Processing

Generate LOD data from existing audio files:

```swift
let snapshot = try await MultiBandLODProcessor.generateFromFile(
    url: audioURL,
    configuration: MultiBandLODConfiguration(
        bandCount: 5,
        lodRatio: 128,
        bufferSeconds: 600,  // Support up to 10 min
        sampleRate: 44_100
    )
)
```

This reads the entire audio file and produces a complete LOD snapshot suitable for rendering static waveform images.

## Frequency Band Distribution

### Mel Scale (Default)

Bands are distributed according to human auditory perception. Band boundaries are derived from the configured `minFreq`/`maxFreq` and `bandCount` using mel-space interpolation, then converted back to Hz.

For the default configuration (`bandCount=5`, `.mel(minFreq: 40, maxFreq: 15000)`), the crossover frequencies are approximately:
- 663 Hz
- 1811 Hz
- 3926 Hz
- 7822 Hz

| Band | Frequency Range | Content |
|------|-----------------|---------|
| 0 | ~40-663 Hz | Sub-bass, kick drums |
| 1 | ~663-1811 Hz | Bass, lower vocals |
| 2 | ~1.8-3.9 kHz | Midrange, speech |
| 3 | ~3.9-7.8 kHz | Presence, clarity |
| 4 | ~7.8-15 kHz | Brilliance, air |

### Linear Scale

Equal frequency spacing (less perceptually useful but sometimes desired):

```swift
let config = MultiBandLODConfiguration(
    bandCount: 5,
    crossoverMode: .linear
)
```

## Metal Rendering Integration

The LOD snapshot is designed for efficient GPU rendering:

```swift
// Create GPU buffers from snapshot
let minBuffer = device.makeBuffer(
    bytes: snapshot.flatMinBuffer(),
    length: bufferSize,
    options: .storageModeShared
)

let maxBuffer = device.makeBuffer(
    bytes: snapshot.flatMaxBuffer(),
    length: bufferSize,
    options: .storageModeShared
)

// Pass to shader
encoder.setVertexBuffer(minBuffer, offset: 0, index: 1)
encoder.setVertexBuffer(maxBuffer, offset: 0, index: 2)
encoder.setVertexBuffer(rmsBuffer, offset: 0, index: 3)
```

**Shader Uniforms:**
```metal
struct Uniforms {
    float zoom;
    float viewOffset;
    float screenWidth;
    float screenHeight;
    float separation;      // Band visual separation
    int bandCount;
    int paletteMode;
    int bufferLength;      // snapshot.rawBufferLength
    int lodRatio;          // snapshot.lodRatio
    int writeIndex;        // snapshot.writeIndex
};
```

## Performance Characteristics

### Memory

Buffer size formula:
```
lodLength = (sampleRate * bufferSeconds) / lodRatio
memoryPerBand = lodLength * 3 * sizeof(Float)  // min, max, rms
totalMemory = memoryPerBand * bandCount
```

Example (5 bands, 300s, 128 ratio, 44.1kHz):
```
lodLength = (44100 * 300) / 128 = 103,359
memoryPerBand = 103,359 * 3 * 4 = ~1.2 MB
totalMemory = ~6 MB
```

### CPU

- Filter bank uses efficient biquad cascades
- LOD computation is O(1) per sample
- `snapshot()` creates a copy (~6MB allocation at 300s)

### Recommended Configurations

| Use Case | Bands | LOD Ratio | Buffer |
|----------|-------|-----------|--------|
| Live recording | 5 | 128 | 300s |
| Thumbnail generation | 5 | 128 | 600s |
| Detailed view | 5-8 | 64 | 300s |

## Topics

### Configuration
- ``MultiBandLODConfiguration``
- ``CrossoverMode``

### Data Types
- ``MultiBandLODSnapshot``
- ``BandLODData``

### Processing
- ``MultiBandLODProcessor``
- ``AudioVisualizationEngine``
