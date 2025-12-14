# Migration TODOs: App → Library

This document tracks behaviors currently in the demo app (`AppLibrary`) that should be migrated into the core `AIOEngine` library for broader reusability.

## High Priority - Core Audio Domain

### 1. Sound Classification API

**Current Location:** `AppLibrary/Services/SoundClassificationService.swift` (160 lines)

**What it does:**
- Uses Apple's SoundAnalysis framework (`SNClassifySoundRequest`)
- Classifies audio files post-recording
- Returns sound identifiers with confidence scores
- Groups results and keeps highest confidence per sound type

**Why it belongs in the library:**
- Sound classification is a core audio analysis feature
- Many audio apps need this functionality
- The core classification logic is generic and reusable
- Database integration is app-specific, but analysis is not

**Migration plan:**
```swift
// Proposed library API
public struct SoundClassification {
    let identifier: String          // e.g., "speech", "music", "applause"
    let confidence: Double          // 0.0-1.0
    let timestamp: TimeInterval?    // Optional time offset in audio
}

public protocol SoundClassifier {
    func classify(audioURL: URL) async throws -> [SoundClassification]
    func classify(
        audioURL: URL,
        minimumConfidence: Double
    ) async throws -> [SoundClassification]
}

// Default implementation using Apple SoundAnalysis
public final class AppleSoundClassifier: SoundClassifier {
    public init(minimumConfidence: Double = 0.5)
    public func classify(audioURL: URL) async throws -> [SoundClassification]
}
```

**Tasks:**
- [ ] Extract classification logic from `SoundClassificationService`
- [ ] Create `SoundClassifier` protocol in `AIOEngine/Analysis/`
- [ ] Implement `AppleSoundClassifier` using SNClassifySoundRequest
- [ ] Remove database dependency (leave to app layer)
- [ ] Add error types: `classificationFailed`, `unsupportedFormat`
- [ ] Write unit tests with mock audio files
- [ ] Document in README

**Leave in app:**
- Database storage of classifications (`TrackClassification` model)
- UI integration (ClassificationChip views)
- Background processing queue

---

### 2. Transcription Service API

**Current Location:** `AppLibrary/Services/TranscriptionService.swift` (260 lines)

**What it does:**
- Dual transcription providers:
  1. Apple Speech Framework (system speech recognition)
  2. Parakeet V3 (FluidAudio on-device ML model)
- Language locale support (default: en_US)
- Token bucket rate limiting (1 concurrent task)
- Status tracking: pending → completed/failed
- Embedding generation post-transcription

**Why it belongs in the library:**
- Speech-to-text is a common audio processing task
- Provider abstraction is reusable across apps
- Core transcription logic is generic
- Status tracking can be simplified for library use

**Migration plan:**
```swift
// Proposed library API
public struct Transcription {
    let text: String
    let locale: Locale
    let confidence: Double?           // Provider-specific
    let segments: [TranscriptionSegment]?  // Time-aligned words
}

public struct TranscriptionSegment {
    let text: String
    let timestamp: TimeInterval
    let duration: TimeInterval
    let confidence: Double
}

public protocol TranscriptionProvider {
    var supportedLocales: [Locale] { get }
    func transcribe(
        audioURL: URL,
        locale: Locale
    ) async throws -> Transcription
}

// Apple Speech implementation
public final class AppleTranscriptionProvider: TranscriptionProvider {
    public init(requiresOnDeviceRecognition: Bool = true)
}

// Parakeet implementation (optional, requires FluidAudio dependency)
#if canImport(FluidAudio)
public final class ParakeetTranscriptionProvider: TranscriptionProvider {
    public init(modelURL: URL)
}
#endif

// Coordinator
public final class TranscriptionCoordinator {
    public init(provider: TranscriptionProvider)

    public func transcribe(
        audioURL: URL,
        locale: Locale = .current
    ) async throws -> Transcription
}
```

**Tasks:**
- [ ] Create `TranscriptionProvider` protocol in `AIOEngine/Analysis/`
- [ ] Extract Apple Speech logic into `AppleTranscriptionProvider`
- [ ] Extract Parakeet logic into optional `ParakeetTranscriptionProvider`
- [ ] Create `TranscriptionCoordinator` for orchestration
- [ ] Remove database status tracking (leave to app)
- [ ] Remove embedding generation (app-specific AI feature)
- [ ] Add error types: `transcriptionFailed`, `noSpeechDetected`, `languageNotSupported`
- [ ] Write unit tests with sample audio
- [ ] Document in README with both providers

**Leave in app:**
- Database storage (`Transcription` model with status)
- Embedding generation (Chroma AI integration)
- Background processing queue
- UI presentation

---

### 3. Waveform Generation (Non-UI)

**Current Location:** `AppLibrary/UI/Waveform/WaveformGenerator.swift` (mixed with UI)

**What it does:**
- Converts audio buffer data to visualization points
- Two modes:
  1. **Real-time**: Streaming waveform during recording
  2. **Post-recorded**: Full waveform for completed files
- Caches waveform images for performance
- Integrates with SwiftUI views

**Why it belongs in the library:**
- Core audio-to-data conversion is generic
- Waveform generation is a common need (not just SwiftUI)
- Real-time streaming logic is reusable
- Image rendering and caching are app-specific

**Migration plan:**
```swift
// Proposed library API
public struct WaveformData {
    let samples: [Float]        // Amplitude values (-1.0 to 1.0)
    let sampleRate: Double      // Samples per second
    let duration: TimeInterval  // Total duration
}

public protocol WaveformGenerator {
    func generate(from audioURL: URL, targetSamples: Int) async throws -> WaveformData
    func generate(from buffer: AVAudioPCMBuffer, targetSamples: Int) -> WaveformData
}

// Default implementation
public final class DefaultWaveformGenerator: WaveformGenerator {
    public init()

    public func generate(
        from audioURL: URL,
        targetSamples: Int
    ) async throws -> WaveformData

    public func generate(
        from buffer: AVAudioPCMBuffer,
        targetSamples: Int
    ) -> WaveformData
}

// Real-time streaming generator
public final class StreamingWaveformGenerator: BufferReceiver {
    public var currentData: WaveformData { get }

    public init(targetSamples: Int, updateInterval: Duration)

    public func processBuffer(_ data: UnsafeBufferPointer<Float>)
    public func endBufferTask()
}
```

**Tasks:**
- [ ] Create `WaveformGenerator` protocol in `AIOEngine/Visualization/`
- [ ] Extract non-UI waveform logic from `WaveformGenerator.swift`
- [ ] Implement `DefaultWaveformGenerator` for static audio files
- [ ] Implement `StreamingWaveformGenerator` conforming to `BufferReceiver`
- [ ] Add downsampling algorithm (peak/RMS) for efficient visualization
- [ ] Remove SwiftUI dependencies (image rendering)
- [ ] Add error types: `waveformGenerationFailed`, `invalidAudioFormat`
- [ ] Write unit tests with fixture audio files
- [ ] Document in README with examples

**Leave in app:**
- SwiftUI views (`WaveformView`, `ContinuousWaveformShape`, `ChunkedWaveformShape`)
- Image caching (`WaveformImageCache`)
- View rendering and styling
- Color/theme integration

---

## Medium Priority - Quality of Life

### 4. Audio Route Management Enhancement

**Current State:** Basic port switching exists in `AIOEngine`

**What's missing:**
- Comprehensive input/output device enumeration
- Default device selection logic
- Capability detection (e.g., built-in mic vs. external interface)
- Port availability monitoring
- Graceful fallback when preferred port unavailable

**Why it belongs in the library:**
- Audio routing is core engine functionality
- App-agnostic device management
- Better interruption handling

**Migration plan:**
```swift
// Proposed library API
public struct AudioRoute {
    let port: AVAudioSessionPortDescription
    let name: String
    let type: AVAudioSession.Port
    let channels: Int
    let isAvailable: Bool
    let capabilities: RouteCapabilities
}

public struct RouteCapabilities {
    let supportsHighSampleRates: Bool
    let supportsMultiChannel: Bool
    let isWireless: Bool
    let isBuiltIn: Bool
}

public final class AudioRouteManager {
    public var availableInputs: [AudioRoute] { get }
    public var availableOutputs: [AudioRoute] { get }
    public var currentInput: AudioRoute? { get }
    public var currentOutput: AudioRoute? { get }

    // Async streams for monitoring
    public var inputChanges: AsyncStream<[AudioRoute]> { get }
    public var outputChanges: AsyncStream<[AudioRoute]> { get }

    public func selectPreferredInput(
        preferring: [AVAudioSession.Port]
    ) async throws -> AudioRoute

    public func selectPreferredOutput(
        preferring: [AVAudioSession.Port]
    ) async throws -> AudioRoute
}
```

**Tasks:**
- [ ] Create `AudioRouteManager` in `AIOEngine/Env/`
- [ ] Implement comprehensive port enumeration
- [ ] Add capability detection (sample rates, channels, etc.)
- [ ] Create async streams for route availability changes
- [ ] Add default selection logic (prefer external, fallback to built-in)
- [ ] Integrate with existing `switchInput`/`switchOutput` methods
- [ ] Add error types: `routeNotAvailable`, `routeCapabilityMismatch`
- [ ] Write unit tests (mock AVAudioSession)
- [ ] Document in README

**Leave in app:**
- UI for route selection
- User preference persistence

---

### 5. Recording Recovery Service

**Current Location:** `AppLibrary/Services/RecoveryService.swift` (crash recovery)

**What it does:**
- Detects incomplete recordings on app startup
- Identifies orphaned audio files
- Cleans up temporary files
- Reconciles database state

**Why it belongs in the library:**
- Crash detection pattern is generic
- File cleanup is core functionality
- Every audio app needs recovery logic

**Migration plan:**
```swift
// Proposed library API
public struct IncompleteRecording {
    let url: URL
    let startedAt: Date?
    let estimatedDuration: TimeInterval?
}

public protocol RecoveryDelegate {
    func shouldRecover(_ recording: IncompleteRecording) async -> Bool
    func didRecover(_ recording: IncompleteRecording)
    func didDiscard(_ recording: IncompleteRecording)
}

public final class RecordingRecoveryService {
    public init(
        recordingDirectory: URL,
        delegate: RecoveryDelegate?
    )

    public func detectIncompleteRecordings() async throws -> [IncompleteRecording]

    public func recover(_ recording: IncompleteRecording) async throws -> URL

    public func discard(_ recording: IncompleteRecording) async throws
}
```

**Tasks:**
- [ ] Create `RecordingRecoveryService` in `AIOEngine/Utils/`
- [ ] Extract crash detection logic from app
- [ ] Implement incomplete recording detection (marker files, timestamps)
- [ ] Add delegate pattern for app-specific recovery decisions
- [ ] Implement file cleanup utilities
- [ ] Remove database reconciliation (leave to app)
- [ ] Add error types: `recoveryFailed`, `corruptedRecording`
- [ ] Write unit tests with simulated crashes
- [ ] Document in README

**Leave in app:**
- Database state reconciliation
- UI for recovery prompts
- User decision logic

---

### 6. Enhanced Error Management

**Current State:** Basic error streaming exists (`engine.errors`)

**What's missing:**
- Error categorization (transient, permanent, recoverable)
- Retry logic and backoff strategies
- Error history and analytics
- Detailed error context (stack traces, system state)

**Migration plan:**
```swift
// Proposed library API
public enum ErrorSeverity {
    case warning    // Non-critical, can continue
    case error      // Operation failed, but recoverable
    case critical   // System-level failure
}

public enum ErrorCategory {
    case hardware   // Microphone, speakers, route changes
    case format     // Conversion, compatibility
    case system     // Audio session, permissions
    case storage    // File I/O, disk space
    case network    // Streaming (future)
}

public struct AIOErrorContext {
    let error: AIOError
    let severity: ErrorSeverity
    let category: ErrorCategory
    let timestamp: Date
    let isTransient: Bool
    let canRetry: Bool
    let systemState: [String: Any]  // Audio session state, routes, etc.
}

public final class ErrorManager {
    // Async stream of all errors with context
    public var errors: AsyncStream<AIOErrorContext> { get }

    // Filtered streams
    public func errors(
        ofSeverity severity: ErrorSeverity
    ) -> AsyncStream<AIOErrorContext>

    public func errors(
        inCategory category: ErrorCategory
    ) -> AsyncStream<AIOErrorContext>

    // Error history
    public func recentErrors(limit: Int) -> [AIOErrorContext]
}
```

**Tasks:**
- [ ] Enhance existing `ErrorManager` in `AIOEngine/Env/`
- [ ] Add error categorization and severity levels
- [ ] Capture system state on error (audio session details)
- [ ] Implement error history tracking
- [ ] Add retry logic helpers
- [ ] Create filtered error streams
- [ ] Write unit tests for error handling
- [ ] Document in README

**Leave in app:**
- UI error presentation
- Analytics integration
- User notifications

---

## Lower Priority - Future Considerations

### 7. Audio Effects Chain

**Status:** Not currently implemented anywhere

**What it would be:**
- Pluggable audio processing pipeline
- Built-in effects: EQ, compression, reverb, normalization
- Custom effect support via protocol

**Why it belongs in the library:**
- Audio effects are generic processing
- Real-time DSP is core functionality
- Reusable across many audio apps

**Migration plan:**
```swift
// Proposed library API
public protocol AudioEffect: Sendable {
    func process(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer
    var isRealTimeSafe: Bool { get }  // Can run on audio thread
}

public final class AudioEffectChain {
    public init()

    public func add(_ effect: AudioEffect)
    public func remove(_ effect: AudioEffect)
    public func process(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer
}

// Built-in effects
public final class EqualizerEffect: AudioEffect {
    public init(bands: [EqualizerBand])
}

public final class CompressorEffect: AudioEffect {
    public init(threshold: Float, ratio: Float)
}
```

**Tasks:**
- [ ] Design `AudioEffect` protocol
- [ ] Create `AudioEffectChain` for serial processing
- [ ] Implement built-in effects (EQ, compressor, normalize)
- [ ] Integrate with recording pipeline
- [ ] Add bypass/wet-dry mix support
- [ ] Write unit tests for each effect
- [ ] Document in README

**Leave in app:**
- Effect UI controls
- Presets and user settings

---

### 8. Batch Processing Utilities

**Status:** Not implemented

**What it would be:**
- Process multiple audio files in parallel
- Apply effects, conversions, analysis to collections
- Progress reporting and cancellation

**Migration plan:**
```swift
// Proposed library API
public struct BatchOperation<T> {
    let audioURL: URL
    let operation: (URL) async throws -> T
}

public final class BatchProcessor {
    public init(maxConcurrent: Int = 4)

    public func process<T>(
        operations: [BatchOperation<T>],
        progress: ((Double) -> Void)?
    ) async throws -> [T]

    public func cancel()
}
```

**Tasks:**
- [ ] Create `BatchProcessor` in `AIOEngine/Utils/`
- [ ] Implement concurrent operation queue
- [ ] Add progress reporting
- [ ] Add cancellation support
- [ ] Write unit tests
- [ ] Document in README

---

## Summary Table

| Feature | Priority | Complexity | Lines to Migrate | Target Module |
|---------|----------|------------|------------------|---------------|
| Sound Classification | High | Medium | ~100 | `AIOEngine/Analysis/` |
| Transcription Service | High | High | ~200 | `AIOEngine/Analysis/` |
| Waveform Generation | High | Medium | ~150 | `AIOEngine/Visualization/` |
| Route Management | Medium | Medium | ~80 | `AIOEngine/Env/` |
| Recovery Service | Medium | Low | ~50 | `AIOEngine/Utils/` |
| Enhanced Error Mgmt | Medium | Low | ~40 | `AIOEngine/Env/` |
| Effects Chain | Low | High | ~0 (new) | `AIOEngine/Processing/` |
| Batch Processing | Low | Medium | ~0 (new) | `AIOEngine/Utils/` |

**Total estimated migration:** ~620 lines of existing code + new features

---

## Migration Guidelines

### When migrating code:

1. **Remove UI dependencies**
   - Extract business logic from SwiftUI views
   - Separate data processing from presentation
   - Keep view models in the app

2. **Remove database dependencies**
   - Provide in-memory results instead of database writes
   - Use protocols for persistence (let app implement)
   - Return data structures, not database models

3. **Maintain Swift 6 concurrency**
   - All new code must be strict concurrency compliant
   - Use Sendable types
   - Proper actor isolation

4. **Write tests first**
   - Add unit tests before migration
   - Test with mock data
   - Aim for >80% coverage

5. **Document thoroughly**
   - Add Swift-doc comments to public APIs
   - Update README with examples
   - Create migration guide for apps

6. **Preserve app features**
   - Don't remove functionality from demo app
   - App should use new library APIs
   - Demonstrate library capabilities

---

## Testing Strategy

For each migrated feature:

1. **Unit tests** - Core functionality with mocks
2. **Integration tests** - End-to-end with real audio files
3. **Performance tests** - Real-time processing benchmarks
4. **Regression tests** - Ensure no breaking changes

Test fixtures needed:
- Sample audio files (various formats, sample rates)
- Mock AVAudioSession for route testing
- Simulated crash scenarios
- Edge cases (zero-length files, corrupted audio, etc.)

---

## Timeline Estimate

**Phase 1: High Priority** (4-6 weeks)
- Week 1-2: Sound Classification API
- Week 2-3: Transcription Service
- Week 3-4: Waveform Generation
- Week 5-6: Testing, documentation, demo app updates

**Phase 2: Medium Priority** (3-4 weeks)
- Week 7-8: Route Management + Recovery Service
- Week 9-10: Enhanced Error Management
- Week 10: Testing, documentation

**Phase 3: Low Priority** (4-6 weeks, optional)
- Week 11-13: Audio Effects Chain
- Week 14-15: Batch Processing
- Week 16: Testing, documentation

**Total: 11-16 weeks for complete migration**

---

## Success Criteria

Migration is successful when:

- [ ] All high-priority features extracted to library
- [ ] Demo app uses new library APIs (no duplicate code)
- [ ] Test coverage >80% for migrated code
- [ ] README fully updated with examples
- [ ] DocC documentation generated
- [ ] No breaking changes to existing engine API
- [ ] Performance benchmarks show no regression
- [ ] Demo app functionality unchanged (feature parity)

---

Last updated: 2025-11-08
