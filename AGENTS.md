# AIO Package - Audio I/O Engine

**Location**: `Packages/AIO/`
**Last Updated**: 2026-05-27

`CLAUDE.md` in this directory is a symlink to this file.

## Purpose

AIO (Audio I/O) is the core audio recording and processing engine for Recorder‽. It provides low-level audio handling, real-time processing, and visualization capabilities.

## Architecture

The package still exposes three public library products, but the implementation is now split by
runtime ownership rather than treating `AIOEngine` as the only meaningful target.

### Public Products

#### Tools
**Location**: `Sources/Tools/`
**Purpose**: Core async utilities and low-level primitives

Contains:
- concurrency/data structures such as `Synchronized`, `Mut`, `SPSCRingBuffer`, and `AsyncBroadcaster`
- general-purpose utilities shared by the rest of the package
- no dependency on the engine/runtime layers

**Dependencies**:
- swift-atomics (Atomics)
- swift-collections (DequeModule, OrderedCollections)
- swift-async-algorithms (AsyncAlgorithms)

#### AudioSignals
**Location**: `Sources/AudioSignals/`
**Purpose**: Visualization data layer — LOD extraction, offline processing, and heuristics for waveform rendering

Contains:
- `MultiBandLODSnapshot` — immutable snapshot of multi-band LOD data
- `MultiBandLODConfiguration` — configuration for LOD generation
- `MultiBandLODProcessor` — realtime sample-to-LOD processor
- `WaveformLODHeuristics` — LOD ratio recommendations based on file length
- `OfflineLODExtractor` — offline file/segment LOD extraction with explicit channel strategy

**Dependencies**:
- Tools (local)

#### AIOEngine
**Location**: `Sources/AIOEngine/`
**Purpose**: Source-compatible compatibility facade and re-export layer

Contains:
- `AIOEngineExports.swift` re-exporting the internal runtime targets
- AIO-owned runtime contracts used by AppLibrary (`RecordingDriving`,
  `AudioEnvironmentDriving`, `AudioEnvironmentConfiguring`,
  `AudioEnvironmentEventSubscribing`, `OutputConfigurationProviding`)
- interruption and testing facade extensions

### Internal Runtime Targets

#### AIOContracts
**Location**: `Sources/AIOContracts/`
**Purpose**: Shared engine-facing contracts

Contains:
- `BufferReceiver` / `BufferTiming`
- `AudioSessionDelegate`

#### AIOSupport
**Location**: `Sources/AIOSupport/`
**Purpose**: Shared package-internal support helpers

Contains:
- logging support and other internal helpers used across targets

#### AIOAudioSession
**Location**: `Sources/AIOAudioSession/`
**Purpose**: Audio session, environment, input/output, and error-reporting runtime

Contains:
- `AudioEnvironmentManager`
- `OutputConfigurationManager`
- audio input/source/sample-rate/channel-count types
- `ErrorManaging`, `AnyErrorManager`, and `MockErrorManager`

#### AIOEngineCore
**Location**: `Sources/AIOEngineCore/`
**Purpose**: Core `AIOEngine` type, shared observable state, and audio-session/playback bridge

Contains:
- `AIOEngine.swift`
- shared recording/playback state and queues
- audio-session configuration helpers
- playback state helpers

#### AIORecording
**Location**: `Sources/AIORecording/`
**Purpose**: Recording runtime and tap lifecycle

Contains:
- `RecordingRuntime`
- `RecordingEngineRuntime`
- recording reconciliation
- tap install/reinstall and receiver/writer/stop orchestration
- recording-oriented facade shims for `AIOEngine`

#### AIORecordingSupport
**Location**: `Sources/AIORecordingSupport/`
**Purpose**: Recording-only state/support substrate shared by core and runtime layers

Contains:
- `RecordingInfrastructure`
- `RecordingRuntimeState`
- `RecordingState`, `WriterSession`, `ReceiverSession`
- tap snapshot, writer backend, and drain-support types

#### AIOPlayback
**Location**: `Sources/AIOPlayback/`
**Purpose**: Playback runtime ownership

Contains:
- `PlaybackRuntime`
- file/segment scheduling
- scrub/reseek and playback polling

#### AIOVisualization
**Location**: `Sources/AIOVisualization/`
**Purpose**: Live visualization runtime

Contains:
- `AudioVisualizationEngine`
- `VisualizationProcessor` for RT-safe ingestion/snapshot work
- `VisualizationHub` for subscriber bookkeeping and event masking

#### AIOMicHealth
**Location**: `Sources/AIOMicHealth/`
**Purpose**: Microphone health monitoring

Contains:
- `MicHealthMonitor`
- `MicHealthState`, `MicHealthInputs`, `MicHealthThresholds`
- `PendingTrackEvent`

## Refactor Status

The AIO refactor has landed substantially, but not every end-state goal is finished.

Implemented:
- AppLibrary now depends on AIO-owned runtime contracts.
- Visualization processing and subscriber fan-out are split.
- Internal package targets now reflect session, recording, playback, visualization, and contracts.
- `AudioEnvironmentManager` is now a facade over extracted environment/session collaborators.
- Recording implementation is split between `RecordingRuntime` and `RecordingEngineRuntime`, with `AIOEngine+Recording.swift` reduced to forwarding shims.

Still active:
- `AIOEngineCore` still owns the shared observable state spine and some cross-runtime helpers.
- `AIOEngine` remains source-compatible, but the proposal’s final end state would push even more core-shell responsibility out of `AIOEngineCore`.

## Products

The package exposes three public library products:
- **Tools**: Core utilities library (for standalone use)
- **AudioSignals**: Visualization data layer (depends on Tools only)
- **AIOEngine**: Public engine surface that re-exports the internal AIO runtime targets

## Testing

The package has comprehensive test coverage:

### ToolsTests
**Location**: `Tests/ToolsTests/`
**Tests**: Core types and utilities (RingBuffer, Synchronized, etc.)

### AIOTests
**Location**: `Tests/AIOTests/`
**Tests**: Engine/runtime functionality (route changes, interruptions, recording, receiver lifecycle, visualization fan-out)

### AudioVisualizationTests
**Location**: `Tests/AudioVisualizationTests/`
**Tests**: Visualization data generation and performance benchmarks

### AIOMicHealthTests
**Location**: `Tests/AIOMicHealthTests/`
**Tests**: Microphone health monitoring

## Building & Testing

Preferred: use XcodeBuildMCP (MCP server or `xcodebuildmcp` CLI) for builds/tests (workspace + simulator aware). Use raw `xcodebuild` only as a backup when neither is available.

If you're iterating on parts of the package that can run directly on the host (no iOS-only APIs), prefer SwiftPM via `xcrun` for fast feedback.

### Preferred (XcodeBuildMCP MCP server or CLI)
See `docs/HOWTO/DETAILS_BUILD_MCP.md`. Use the hosted iOS workspace scheme `AIOiOSTests` (or `AudioVisualizationiOSTests`) with `mcp__XcodeBuildMCP__test_sim`, or run the SwiftPM test targets `AIOTests`, `ToolsTests`, `AudioVisualizationTests`, and `AIOMicHealthTests` directly via `xcrun swift test` when simulator hosting is not needed.

### Host SwiftPM (When Compatible)
```bash
xcrun swift test --package-path Packages/AIO
```

### Backup (iOS Simulator via raw Xcode CLI)
```bash
xcodebuild test -workspace Recorder.xcworkspace -scheme AIOiOSTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath "${TMPDIR:-/tmp}/RecorderDerivedData/AIOiOSTests"
```

### Claude Code Slash Commands (Optional)
If you're using Claude Code in this repo, see `.claude/AGENTS.md` for the full slash-command list (including `/test-aio`).

### Test Framework
Tests use **Swift Testing** framework (`@Test` macros, `@Suite`), not XCTest.

## Agent Workflow

- Always run the relevant AIO test suite before considering work complete. Prefer the narrowest meaningful suite first (`xcrun swift test --package-path Packages/AIO` when host-compatible, or the matching XcodeBuildMCP/Xcode test scheme when simulator coverage is needed), and report what you ran.
- Always commit finished work on the current checked-out branch after tests pass. Do not create or switch branches unless the user explicitly asks. This includes `main` — if the session started with `main` checked out and no branch or worktree was requested, commit directly to `main` without asking first.

## Key Features

- **Swift 6 Concurrency**: Full strict concurrency checking
- **Platform Support**: iOS 26+, macOS 26+
- **Real-time Audio**: Low-latency audio processing
- **Type Safety**: Strong typing with Swift 6
- **Modular**: Clear separation between Tools and Engine
- **Multi-Band Visualization**: Frequency-separated LOD waveform data for GPU rendering

## Error Reporting (Injection Boundary)

The engine exports a narrow, injectable interface for error reporting:

- `ErrorManaging` (protocol)
- `AnyErrorManager` (type erasure)
- `MockErrorManager` (debug-only test double)

**Location**: `Sources/AIOAudioSession/Env/ErrorManaging.swift`

Policy:
- View/UI layers may keep a concrete `ErrorManager` via environment access.
- Business logic layers should accept `any ErrorManaging` via constructor injection (non-optional) so missing wiring is caught at build time.

## Audio Visualization

The package provides multi-band Level-of-Detail (LOD) visualization:

### Quick Start
```swift
let request = VisualizationRequest(
    work: VisualizationWork(lod: LODWork(configuration: .default, publishRateHz: 60))
)
let subscription = vizEngine.subscribe(request: request) { _ in }
vizEngine.startVisualization()

// Feed audio samples
vizEngine.processBuffer(audioSamples)

// Frame-scoped read for rendering
vizEngine.withCurrentLODSnapshotRef { snapshot in
    let flatMin = snapshot.copyContiguousLODChannel(.min)
    _ = flatMin
}

subscription.cancel()
```

### Offline Generation
```swift
let extractor = OfflineLODExtractor(configuration: .default)
let snapshot = try await extractor.extract(from: audioURL).snapshot
```

See `Sources/AIO.docc/MultiBandVisualization.md` for complete API documentation.

## Documentation (DocC)

**Location**: `Sources/AIO.docc/`

Technical specs and design documents for the audio engine:

- `AIO.md` - DocC catalog landing page
- `README.md` - DocC catalog overview
- `Architecture.md` - Package architecture overview
- `Development.md` - Development guidance
- `Features.md` - Feature overview
- `SPEC_AIO.md` - AIO engine spec (architecture, recording pipeline, error handling)
- `SPEC_AUDIO_VIZ.md` - Audio visualization pipeline spec
- `core-audio-layer-opportunities.md` - Core Audio layer opportunities
- `MultiBandVisualization.md` - Multi-band LOD API documentation
- `MultiBandLODContract.md` - Multi-band LOD data contract

## Development Guidelines

### Concurrency
- Use actors for mutable state
- Mark types `Sendable` appropriately
- Use structured concurrency (`async`/`await`)
- Avoid `@unchecked Sendable` unless necessary

### Testing
- Test Tools and Engine separately
- Test visualization independently
- Use Swift Testing framework (`@Test` macros)
- Run tests before committing

### Dependencies
- Tools should have minimal dependencies
- AIOEngine can depend on Tools
- Keep external dependencies to minimum

## Integration

AIO is consumed by:
- **Packages/AppLibrary/AppTarget**: Main app logic
- **Packages/AppLibrary/ExtensionLib**: Widget extensions

The package is referenced via local path from AppLibrary:
```swift
.package(path: "../AIO")
```

Changes to AIO require rebuilding AppLibrary.

AppLibrary should prefer the AIO-owned runtime contracts re-exported from `AIOEngine`:
- `RecordingDriving`
- `AudioEnvironmentDriving`
- `OutputConfigurationProviding`

## Performance Considerations

- Audio processing runs in real-time
- Minimize allocations in hot paths
- Use appropriate data structures (OrderedCollections, DequeModule)
- Profile with Instruments when needed

## Platform Specifics

The package uses conditional compilation:
```swift
platforms: Platforms.apple  // iOS 26+, macOS 26+
```

Can be disabled with `NO_PLATFORMS` environment variable for testing.
