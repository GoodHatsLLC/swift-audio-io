# AIO Package - Audio I/O Engine

**Last Updated**: 2025-11-28

## Purpose

AIO (Audio I/O) is the core audio recording and processing engine for Recorder‽. It provides low-level audio handling, real-time processing, and visualization capabilities.

## Architecture

The package is split into multiple targets for modularity:

### Tools
**Location**: `Sources/Tools/`
**Purpose**: Core audio types, utilities, and fundamental building blocks

Contains:
- Platform-independent audio types
- Core data structures (RingBuffer, Synchronized, etc.)
- Utility functions
- No dependencies on AIOEngine

**Dependencies**:
- swift-atomics (Atomics)
- swift-collections (OrderedCollections)
- swift-async-algorithms (AsyncAlgorithms)

**Swift**: 6.2 with strict concurrency enabled

### AIOEngine
**Location**: `Sources/AIOEngine/`
**Purpose**: Audio recording engine and processing pipeline

Contains:
- Audio recording logic
- Real-time processing
- Audio stream management
- Visualization data generation

**Dependencies**:
- Tools (local)
- SystemLog (local)
- swift-atomics, swift-collections, swift-async-algorithms

**Swift**: 6.2 with strict concurrency enabled

### SystemLog
**Location**: `Sources/SystemLog/`
**Purpose**: Logging utilities for the audio engine

Contains:
- Structured logging
- Performance monitoring
- Debug output

**Swift**: 6.2 with strict concurrency enabled

## Products

The package exposes two library products:
- **Tools**: Core utilities library (for standalone use)
- **AIOEngine**: Full audio engine library (includes Tools)

## Testing

The package has comprehensive test coverage:

### ToolsTests
**Location**: `Tests/ToolsTests/`
**Tests**: Core types and utilities (RingBuffer, Synchronized, etc.)

### AIOTests
**Location**: `Tests/AIOTests/`
**Tests**: Engine functionality (recording configuration, tap configuration)

### AudioVisualizationTests
**Location**: `Tests/AudioVisualizationTests/`
**Tests**: Visualization data generation and performance benchmarks

## Building & Testing

**IMPORTANT**: All builds and tests must target iOS simulator or iOS devices. The package uses iOS-specific APIs (AVAudioSession) that aren't available on macOS.

### From Package Directory (iOS Simulator)
```bash
cd AIO
# Build and test for iOS simulator
xcodebuild test -scheme AIO-Package -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -derivedDataPath ../.DerivedData
```

### Using Claude Code
```bash
/test-aio        # Run all AIO tests on iOS simulator
/test            # Run all tests including AIO
```

### Test Framework
Tests use **Swift Testing** framework (`@Test` macros, `@Suite`), not XCTest.

## Key Features

- **Swift 6 Concurrency**: Full strict concurrency checking
- **Platform Support**: iOS 18+, macOS 15+
- **Real-time Audio**: Low-latency audio processing
- **Type Safety**: Strong typing with Swift 6
- **Modular**: Clear separation between Tools and Engine

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
- **AppLibrary/AppTarget**: Main app logic
- **AppLibrary/ExtensionLib**: Widget extensions

The package is referenced via local path:
```swift
.package(path: "../AIO")
```

Changes to AIO require rebuilding dependent packages.

## Performance Considerations

- Audio processing runs in real-time
- Minimize allocations in hot paths
- Use appropriate data structures (OrderedCollections, DequeModule)
- Profile with Instruments when needed

## Platform Specifics

The package uses conditional compilation:
```swift
platforms: Platforms.apple  // iOS 18+, macOS 15+
```

Can be disabled with `NO_PLATFORMS` environment variable for testing.
