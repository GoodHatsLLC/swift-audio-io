# Unused AIO Code Documentation

This document tracks public APIs in the AIO package that are currently unused in the codebase. These are retained for potential future use.

**Last Updated**: 2025-12-27

---

## Tools/Async - Unused Utilities

### TaskHandle & TaskBuilder
**File**: `Sources/Tools/Async/TaskHandle.swift`

Property wrapper for managing Task lifecycle with automatic cancellation on deinit.

```swift
@TaskHandle var myTask: Task<String, Error>?
```

**Status**: Never adopted in codebase
**Reason**: Alternative patterns used instead

---

### SendableHashable
**File**: `Sources/Tools/Async/SendableHashable.swift`

Type-erased wrapper for `Sendable & Hashable` types.

```swift
let hashable = someValue.sendableHashable()
```

**Status**: Not used
**Reason**: No current use case for type-erased hashable values

---

### AsyncStream+Erasure Utilities
**File**: `Sources/Tools/Async/AsyncStream+Erasure.swift`

Type aliases and extensions for async sequences that start with nil values:

- `AsyncInitiallyNilSequence<Source>`
- `AsyncInitiallyNilOptionalSequence<Source>`
- `InitiallyNilFiringCombineLatest2<Source1, Source2>`
- `AsyncSequence.optionalized()` method
- `AsyncSequence.withNilPrefix()` method

**Status**: Type aliases defined but never referenced
**Reason**: Sophisticated combine-latest patterns not needed yet

---

## Tools/Utils - Unused Utilities

### Existential.isEqual
**File**: `Sources/Tools/Utils/Existential.swift`

Dynamic type-erased equality comparison:

```swift
Existential.isEqual(anyValue1, anyValue2) // -> Bool?
```

**Status**: Not used
**Reason**: Dynamic type checking not needed in current architecture

---

### AnyHashable Variadic Initializer
**File**: `Sources/Tools/Utils/AnyHashable.swift`

Convenience initializer for creating AnyHashable from multiple values:

```swift
AnyHashable(of: value1, value2, value3)
```

**Status**: Not used
**Reason**: No use case for collecting heterogeneous hashable values

---

### Optional.orElse
**File**: `Sources/Tools/Utils/Optional+orElse.swift`

Convenience method for providing default values:

```swift
optionalValue.orElse { computeDefault() }
```

**Status**: Not used (`.orThrow()` in same file IS used)
**Reason**: Swift's `??` operator and nil coalescing sufficient

---

## Partially Used APIs

### AsyncBuffer Replay Variants
**File**: `Sources/Tools/Async/AsyncBroadcaster.swift`

The `AsyncBuffer` enum defines buffering policies:
- `.none` - Used
- `.unbounded` - Used
- `.latest(n)` - Defined but `.broadcast(replay:)` never called with replay

---

## Notes

These utilities are well-designed and may be useful for:
- Future audio processing features
- New async patterns
- Testing infrastructure

**Recommendation**: Retain these utilities. They represent careful API design that may be adopted as the project evolves.
