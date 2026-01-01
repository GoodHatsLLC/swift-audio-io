# AIO Package — Audio I/O Engine

**Location**: `Packages/AIO/`
**Last Updated**: 2025-12-31

## Purpose

AIO (Audio I/O) is the core audio recording and processing engine for Recorder‽. It provides low-level audio handling, real-time processing, and visualization capabilities.

## Targets

### Tools
**Location**: `Sources/Tools/`
**Purpose**: Core audio types and utilities (no dependency on AIOEngine)

**Dependencies**:
- swift-atomics (Atomics)
- swift-collections (OrderedCollections)
- swift-async-algorithms (AsyncAlgorithms)

### AIOEngine
**Location**: `Sources/AIOEngine/`
**Purpose**: Audio recording engine and processing pipeline

**Dependencies**:
- Tools (local)
- SystemLog (local)
- swift-async-algorithms (AsyncAlgorithms)
- swift-atomics (Atomics)
- swift-collections (Collections, DequeModule, OrderedCollections)

### SystemLog
**Location**: `Sources/SystemLog/`
**Purpose**: Structured logging utilities used by the engine

**Dependencies**:
- swift-async-algorithms (AsyncAlgorithms)

## Platform & Swift

- **Platforms**: iOS 18+, macOS 15+
- **Swift**: 6.2 with strict concurrency (`StrictConcurrency` enabled)

## Error Reporting (Injection Boundary)

Business logic in downstream packages should not depend directly on concrete UI error presentation.

This package provides:
- `ErrorManaging` (protocol) — narrow injectable interface for error reporting
- `AnyErrorManager` — type erasure for passing an unknown implementation
- `MockErrorManager` (debug only) — lightweight test double

Implementation lives in:
- `Sources/AIOEngine/Env/ErrorManaging.swift`

Policy:
- UI layer uses concrete `ErrorManager` (often via SwiftUI environment).
- Business logic depends on `any ErrorManaging` via constructor injection (non-optional) so wiring errors are discovered at build time.

## Testing

Tests use Swift Testing (`@Suite` / `@Test`), not XCTest.

Schemes:
- `AIOTests`
- `ToolsTests`
- `AudioVisualizationTests`

Example (iOS Simulator):
```bash
cd Packages/AIO
xcodebuild test -scheme AIOTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

