# Roadmap

This document describes the current state of AudioIO and what we expect to work on next. Dates are deliberately omitted — order is meaningful, calendar weeks are not.

## Current state

AudioIO lives in this standalone repository. All M3 polish work has landed and CI is green. **No `0.x` release is tagged yet** — `0.1.0` is the next step and starts the SemVer commitment.

## Milestones

### M1 — Surface narrowing (complete)

Goal: reduce the public API to a single curated module.

- [x] Rename `AIOEngine` → `AudioIO`. Single public product.
- [x] Replace `@_exported import` re-exports with explicit `public import` / typealias facade where the import-visibility rules permit (3 modules moved to `public import`, 5 retained `@_exported` because consumers call instance methods / static members that `MemberImportVisibility` can't reach through a typealias).
- [x] Audit every `public` symbol; the curated `Exports.swift` typealias list is the canonical surface fixture.
- [x] Strip `import SwiftUI` and `import Combine` from the entire library, enforced by `bin/check-no-swiftui-combine-in-aio.sh`.
- [x] Add `Tests/AIOTests/PublicAPISnapshot.swift` as the API-stability fixture (6 `@Test` functions, one per source module).

Exit criteria: ready to tag `0.1.0` once the M3 CI runner lands.

Not done in M1 (deferred / out of scope):
- Absorbing `Tools` and `AudioSignals` as `@_spi(Internal)` / `@_spi(Visualization)` SPIs — both remain as separate public products. The narrowing argument turned out weaker than expected: `AudioSignals` is independently useful to consumers building waveform UI without the recording stack, and `Tools` already exposes only typed-throws / async primitives that AudioIO itself depends on transitively.

### M2 — API ergonomics (complete)

Goal: one obvious way to do each thing.

- [x] **M2.5** — Replace `SampleRate.Common.sr44100`-style enum API with `ExpressibleByIntegerLiteral` + named statics (`.cd`, `.dvd`, `.hiRes96`, `.hiRes192`) and a `static let common: [SampleRate]` array for UI selectors.
- [x] **M2.4** — Replace dual `avAudio` / `platform` accessors on input types with `@_spi(AVFoundation)` escape hatches. Same gating on AV-taking initializers and the `EncodingQuality.avAudio` bridge.
- [x] **M2.2** — Split `AIOError` into per-domain enums (`RecordingError`, `PlaybackError`, `SessionError`) under the `AudioIOError` marker protocol. Cross-domain wrapping via `.session(_:)` cases.
- [x] **M2.3** — Pick one canonical `startRecording(configuration:) async throws(RecordingError) -> URL` (returns URL on success); demote the reconciliation-mode entry points (`setDesiredRecordingState`, `startRecordingWithReconciliation`, `consumeLastRecordingStartFailure`) to `@_spi(Advanced)`.
- [x] **M2.1** — Replace `errors: AsyncBroadcaster<any Error>` with the typed `events: AsyncBroadcaster<AudioIOEvent>` stream. `AudioIOEvent.error(_:)` is the initial case; lifecycle cases for `recordingStarted/Completed/Failed/Interruption/Segment` and `playbackStateChanged/Updated` are tracked for M3 because the closure callbacks they replace need a separate host-app migration pass.

Exit criteria: ready to tag `1.0.0` once M3 lands. SemVer commitment begins at `1.0.0`.

### M3 — Polish (complete)

Goal: outsiders can adopt without reading the source.

- [x] Migrate the remaining `on*` closure callbacks (recordingStarted/Completed/Failed/Interruption/playbackStateChanged/Updated/reconciliationFailed) into the `events: AsyncBroadcaster<AudioIOEvent>` stream as additional cases. Rework `RecordingCrashTracking.attachRecordingCrashTracking`'s chained-observer dance to consume the events stream via a subscriber task with cancellation. (`onSegmentCompleted` deleted as dead surface — never fired.)
- [x] Flatten visualization configuration type homes and naming. (Redundant `Visualization/` subdirectory lifted; duplicate `VisualizationTypes.swift` filenames resolved by splitting into role-based files; `VisualizationWork`/`LODWork`/`AnalysisWork`/`FrequencyDomainWork` moved from `AudioSignals` to `AIOVisualization` to clarify the signal-domain vs engine-coordination boundary.)
- [x] Rewrite DocC catalog with externally-focused topics (Getting Started, Platform Matrix, Threading Model, Error Handling, Events) plus API-surface reference docs for Recording, Playback, Audio Session, and Visualization. Inside-baseball architecture/spec/development docs dropped.
- [x] Ship the `Examples/AudioIODemo` sample app (iOS + macOS). Minimum-viable single-screen demo (record / play / live waveform / events log); SwiftUI codebase shared across iOS and macOS targets; XcodeGen-generated shell.
- [x] Set up a single macOS GitHub Actions test runner (`macos-26`, Xcode 26.5, one job, no matrix). Runs the full SwiftPM macOS test suite (186 tests) and compiles the iOS-only code paths via `build-for-testing`. The iOS *test run* is deferred: the free-tier GitHub macOS runners are Intel, and the emulated iOS Simulator's CoreAudio stack (`AURemoteIO -10851`) can't run the audio integration tests deterministically. Revisit when free-tier arm64 macOS runners land or on a self-hosted Apple-Silicon runner. DocC publishing is intentionally out of scope — Swift Package Index auto-builds the catalog on each release.
- [x] Execute the `git filter-repo` extraction into the standalone `swift-audio-io` repository.

Exit criteria: `1.0.0` general availability.

## Known follow-ups (post-extraction)

- **iOS test execution in CI** — currently compile-only (see the CI item above). Needs an Apple-Silicon runner.
- **Stale iOS-only test expectations** — surfaced during the CI bring-up but not yet fixed in-repo: the `AAC compatible common sample rate matrix` test expects a rate set without `32 kHz`, which iOS 26 now reports as AAC-compatible; the `AudioVisualizationEngineConsumerTests` fan-out tests have x86-simulator-sensitive `waitForSignal` timeouts. These don't gate CI today (iOS is compile-only) but must be addressed before iOS test execution is re-enabled.
- **`actions/checkout` Node 20 deprecation** — bump to `@v5` (or whatever's current) before September 2026.

## Stability commitments

### Pre-1.0 (`0.x`)

- The public API can change between minor versions. Pin to an exact version (`exact: "0.1.0"`) if that worries you.
- We will not knowingly break the public API in a patch release.
- The deprecation cycle is "one minor version" — a symbol marked deprecated in `0.2.0` may be removed in `0.3.0`.

### Post-1.0

- Source compatibility is preserved across minor and patch versions. Breaking the public API requires a SemVer-major release.
- Deprecations get at least one minor version of warning before removal in the next major.
- SPI surfaces (`@_spi(Internal)`, `@_spi(Visualization)`, `@_spi(Advanced)`, `@_spi(AVFoundation)`) are explicitly **not** covered by the SemVer commitment. They exist for power users who accept tighter coupling.

### Platforms

- We commit to iOS 26+ and macOS 26+ at 1.0. Raising the floor (e.g., to iOS 27) requires a SemVer-major.
- We will not lower the floor below the 1.0 commitment without strong demand and a contributor willing to maintain compatibility.

## Now → Next → Later → Not on the roadmap

### Now

- **M3 is complete.** Lifecycle event-stream migration, visualization config flatten, DocC catalog rewrite, `Examples/AudioIODemo` sample app, the `git filter-repo` extraction (this repo), and the macOS CI runner have all landed. CI is green.

### Next

- Tag `0.1.0`. This is the M3 exit point — the public surface is stable enough to start the `0.x` SemVer commitment.
- `1.0.0` release once the post-`0.1.0` shake-out period closes (and the known follow-ups above — chiefly iOS test execution — are resolved).

### Later (candidates for post-1.0)

These are real candidates but uncommitted. Subscribe to the linked Discussions for updates.

- **`swift-audio-io-views`** — a sibling repository for standalone, opt-in waveform views. Likely SwiftUI-only at first.
- **Plugin AudioUnit hosting** — support for loading and chaining `AUv3` plugins into recording / playback. Significant scope; would require a champion.
- **Sample-accurate sync across multiple AudioIO engines** — a real ask from people building DAW-shaped products. Requires careful thought about session ownership.
- **Linux / non-Apple platform support** — only meaningful with a non-AVFoundation backend; effectively a parallel implementation.
- **Hardware route preferences API** — finer-grained control over `AVAudioSession` route selection beyond the current input-picking environment.

### Not on the roadmap

The following are explicitly *not* planned. See [NOT_AUDIO_IO.md](NOT_AUDIO_IO.md) for the full reasoning.

- General DSP / effects.
- Multi-track editing.
- Network streaming (HLS, WebRTC, AirPlay).
- Cloud sync.
- UI components of any kind.
- Other Apple platforms beyond iOS and macOS.

## How decisions are made

Roadmap items move forward when:

1. A clear use case exists outside a single host app.
2. The API addition fits the spirit-of-the-rules test in [NOT_AUDIO_IO.md](NOT_AUDIO_IO.md).
3. A contributor (often a maintainer) commits to seeing it through, including tests and docs.

If you want to propose moving something from "Later" to "Next," open a Discussion. We respond, but slowly.
