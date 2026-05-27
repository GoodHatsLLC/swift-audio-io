# Contributing to AudioIO

Thanks for your interest. This document covers what you need to know to file a useful issue or submit a PR.

## Before you open an issue or PR

Read **[NOT_AUDIO_IO.md](NOT_AUDIO_IO.md)**. It lists what AudioIO will and won't accept. Saves us both time if your idea is on the "won't" list.

If you're unsure whether something is in scope, open a Discussion (not an issue) and ask.

## Development setup

Requirements:

- macOS 26+ (host)
- Xcode 26+
- Swift 6.3 toolchain (bundled with Xcode 26)

Clone and run the tests:

```bash
git clone https://github.com/GoodHatsLLC/swift-audio-io.git
cd swift-audio-io
xcrun swift test
```

Tests use the **Swift Testing** framework (`@Test` macros), not XCTest.

### Running on the iOS Simulator

Some tests exercise `AVAudioSession`, which requires the simulator:

```bash
xcodebuild test \
  -scheme AudioIO \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### Running the demo app

```bash
cd Examples/AudioIODemo
xcrun swift build
open Package.swift  # then run from Xcode
```

## PR conventions

- **Branch name**: anything, we squash on merge.
- **Title**: imperative mood, no scope prefix needed (`Fix race in RecordingRuntime startup`, not `fix: race in startup`).
- **Size**: small is good. Multi-feature PRs get split.
- **Tests**: every behavior change needs a test. Bug fixes need a regression test that fails before the fix. Refactors need to leave coverage at or above the baseline.
- **Public API changes**: must update `Tests/PublicAPISnapshotTests/PublicAPISnapshot.swift`. If you can't, the change is breaking — see "Stability" below.

### Commit style

Conventional commits are welcome but not required. We care about clear commit messages, not the prefix.

## Stability

While we're at `0.x`, the public API can change between minor versions. Don't propose breaking changes without a justification — but if you have one, we'll consider it.

After `1.0`, breaking changes require a SemVer-major. The bar will be much higher.

### What counts as "public API"

Anything reachable from `import AudioIO` without `@_spi(...)`. Symbols behind `@_spi(Internal)`, `@_spi(Visualization)`, `@_spi(Advanced)`, or `@_spi(AVFoundation)` are explicitly *not* stable — they exist for power users (mostly Recorder‽) who have opted into a tighter coupling.

## Testing requirements

- Every public type is constructed at least once in `Tests/PublicAPISnapshotTests/`. This is the canonical "does the API still exist" check.
- New audio-engine behavior should have a test in `Tests/AudioIOEngineTests/` or the relevant subdirectory.
- Visualization changes need a test in `Tests/VisualizationTests/`.
- Cross-platform behavior must be tested on both iOS Simulator and macOS host targets where applicable.

## Reporting issues

A good issue includes:

1. AudioIO version (or git SHA).
2. Xcode version, Swift version, host OS.
3. Target platform (iOS / macOS, OS version).
4. Minimal reproduction — ideally a snippet that compiles against `AudioIO`.
5. What you expected vs what happened.

Crash reports: include the symbolicated stack trace. Performance reports: include Instruments traces if possible.

## Code of conduct

Be excellent to each other. Constructive disagreement is fine; abuse and harassment are not. The maintainers will block accounts that violate this. English is the working language but you're welcome to write issues in any language; we'll translate.

## License

By submitting a contribution, you agree it will be licensed under Apache-2.0 (the project license). See [LICENSE](LICENSE).
