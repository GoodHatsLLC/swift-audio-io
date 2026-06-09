# AudioIO extraction — progress log

This is the live status of the AudioIO extraction work, distinct from [ROADMAP.md](ROADMAP.md):

- **[ROADMAP.md](ROADMAP.md)** describes the destination — milestone definitions, exit criteria, stability commitments.
- **PROGRESS.md** (this file) tracks the journey — what's landed, what's in flight, what surprised us.

## Currently in flight

### M3 — Polish

Status: **in progress**. Four M3 deliverables landed so far (see Done log below): the lifecycle event-stream migration, the visualization configuration flatten, the DocC catalog rewrite, and the `Examples/AudioIODemo` sample app (single-screen iOS + macOS SwiftUI demo demonstrating the canonical recording / playback / events / visualization idioms). Remaining M3 work: a single macOS GitHub Actions test runner (one job, no matrix — the macOS runner hosts both the SwiftPM macOS suite and the iOS Simulator integration tests) and the `git filter-repo` extraction into `swift-audio-io`. Documentation hosting is delegated to Swift Package Index, which auto-builds DocC from the catalog on each release; no self-hosted DocC publishing pipeline is planned.

### M2 — API shape & ergonomics

Status: **complete** within stated scope (M2.5, M2.4, M2.2, M2.3, M2.1 all landed and validated on macOS + iOS).

### M1 — Surface narrowing

Status: **complete** within scope. Ready to tag `0.1.0` after the extraction `git filter-repo` step.

#### M1.1 — Rename `AIOEngine` → `AudioIO` and replace `@_exported import` facade

Status: **complete**.

Split into two checkpoints after discovery surfaced a larger public surface than initially mapped (see "Surprises"):

**M1.1a — Rename only** (mechanical, low-risk):
- [x] Discovery: map every `public` symbol in internal AIO targets.
- [x] Discovery: map every `import AIO*` / `import Tools` / `import AudioSignals` site in the host app.
- [x] Plan the rename based on discovery.
- [x] Move `Sources/AIOEngine/` → `Sources/AudioIO/` (5 files via `git mv`, including `AIOEngineExports.swift` → `Exports.swift`).
- [x] Update `Packages/AIO/Package.swift`: target + product + test target deps.
- [x] Update `<app-package>/Package.swift`: 6 `.product(name:)` references.
- [x] Update `Packages/AVC/Package.swift`: 2 `.product(name:)` references.
- [x] Update `project.yml`: 6 product references + 1 validate-imports script arg.
- [x] Update all `import AIOEngine` → `import AudioIO` (129 source/test files — agent had to do a second pass for `public import`, `@_spi(TESTING) import`, and `@testable import` forms missed by initial regex).
- [x] Update selective import in `RecordingSheetView.swift:17` (caught by the second-pass regex).
- [x] Code review pass (subagent). 1 HIGH (downgraded — class-name vs module-name disambiguation), 6 MEDIUM (addressed), 3 LOW (deferred to M1.1b).
- [x] Doc cleanup: `Packages/AIO/README.md`, `Packages/AIO/AGENTS.md`, `Sources/AIO.docc/*.md`, `.claude/commands/audio-test.md`. Class-name and target-name references intentionally kept.
- [x] `xcrun swift test --package-path Packages/AIO` passes (180 tests in 31 suites, 0.62s).
- [x] `xcrun swift build --package-path <app-package>` passes (491 modules, 22s).
- [x] Committed: `3a94487b` "Rename AIOEngine product to AudioIO" (M1.1a) and `4e791e6` "Draft AudioIO extraction foundational docs" (Phase 0).

**M1.1a deferred work** (moved to M1.1b backlog):
- Test struct names (`AIOEngineTests`, `AIOEngineBufferCapacityTests`, `AIOEngineIntegrationTests`, `AIOEngineReceiverTests`) and test display name `` `README quickstart type-checks against AIOEngine` ``.
- Test-local DispatchQueue label `"AIOEngine.tap-handler-regression"` and temp directory name `AIOEngineIntegrationTests-…`.
- Internal runtime DispatchQueue labels like `"AIOEngine.receiver"` — verified as referring to the unchanged Swift *class* `AIOEngine`, not the module. Stay correct as-is.

**M1.1b — Explicit-facade rewrite** (curation, completed):
- [x] Replace `@_exported import X` lines in `Exports.swift` with explicit `public typealias` declarations. Outcome: 3 modules demoted to `public import` (not `internal import` — that would break public-typealias access level), 5 modules retained on `@_exported import`. See "Surprises" for why the asymmetry expanded beyond the original 6-vs-2 split.
- [x] Curate the keep-public list (informed by the corrected public-symbol audit). ~70 typealiases added, grouped by source module under `// MARK:` headers.
- [x] Add `Tests/AIOTests/PublicAPISnapshot.swift` (canonical "what's stable" fixture). 6 `@Test` functions, one per source module, each referencing every typealiased symbol via `.self`.
- [x] Code review pass identified 2 documentation gaps (MemberImportVisibility asymmetry for AIOAudioSession; OfflineLODExtractor exclusion comment scope) + 1 missing canary (`MultiBandLODProcessor.LODGenerationError`). Addressed inline.
- [x] Build green: AIO tests 186/186 (180 baseline + 6 snapshot), the app package build clean.

**Discovery facts from agents (verified, post-surprise):**
- 110 files in the host app import `AIOEngine` (88 the app package src + 35 the app package tests + 2 AVC + 2 Harness + …). Zero direct imports of internal AIO targets (`AIOAudioSession`, `AIORecording`, etc.) anywhere. The umbrella has held.
- 23 files import `AudioSignals` (17 the app package + 3 AVC + 6 tests).
- 117+ files import `Tools` (63 the app package src + 54 tests + 2 Harness + 1 AVC).
- One selective import to handle: `Sources/AppTarget/Recording/RecordingSheetView.swift:17` uses `import struct AIOEngine.AudioSource`.
- `<app-package>/Package.swift`: AIOEngine product referenced across 10 targets.
- `project.yml`: AIOEngine referenced in 6 XcodeGen test/harness targets.

## Done

<!-- done-log:start -->

### 2026-05-27 — M3 (sample app): `Examples/AudioIODemo` (iOS + macOS)

Minimum-viable sample app for the AudioIO Swift package. One screen, one record button, one waveform, one play button, one status line. Shared SwiftUI codebase across iOS and macOS targets, XcodeGen-generated Xcode shell, ad-hoc "Sign to Run Locally" code signing so it builds without a development team.

**Layout (5 source files, 1 manifest, 1 README, 0 Info.plist files):**

```
Packages/AIO/Examples/AudioIODemo/
  project.yml                    # XcodeGen manifest, ~60 lines
  README.md                      # what / why / how to run
  AudioIODemo/
    AudioIODemoApp.swift         # @main App scene
    ContentView.swift            # the whole UI
    AudioIODemoViewModel.swift      # @Observable @MainActor engine adapter
    WaveformView.swift           # TimelineView + Canvas reading the LOD snapshot
    PermissionGate.swift         # iOS + macOS microphone permission
```

No physical Info.plist or entitlements file — `INFOPLIST_KEY_*` build settings in `project.yml` cover everything (display name, copyright, microphone usage description, iOS launch screen, scene manifest, interface orientations). Code-signing uses `CODE_SIGN_STYLE: Manual` + `CODE_SIGN_IDENTITY: "-"`, which gives "Sign to Run Locally" semantics without a `DEVELOPMENT_TEAM`, so the sample is portable across machines / orgs.

**Demonstrates (the canonical idioms an adopter is looking for):**

| Idiom | Where |
|---|---|
| Subscribe to `engine.events` BEFORE driving the engine | `AudioIODemoViewModel.init` |
| Pattern-match cases off the unified events stream | `AudioIODemoViewModel.handle(_:)` |
| Typed-throws recording start/stop | `AudioIODemoViewModel.toggleRecording()` |
| Token-scoped buffer-receiver attachment | `AudioIODemoViewModel.attachVisualization()` |
| Subscriber-demand visualization registration | `AudioIODemoViewModel.attachVisualization()` |
| Frame-scoped zero-copy LOD reads in a render loop | `WaveformView.draw(in:size:)` |
| iOS + macOS microphone permission flow | `PermissionGate.swift` |

**Deliberately omitted (the wrong things to demo in a minimum-viable):**

- Recording-list persistence — would suggest the library imposes a UI model.
- Audio-session category negotiation — adopters with that need will reach for the docs.
- Segmented recording — the canonical happy path doesn't need rotation.
- Frequency-domain / beat detection — the `LODWork`-only demand keeps the demo focused on waveform rendering.
- Recording-mode SPI — the canonical `startRecording(configuration:)` is the right thing to show, not `setDesiredRecordingState`.

**Async-usage policy:** `Packages/AIO/Examples/` is added to the path allowlist. The sample uses raw `Task { for await event in engine.events { ... } }` because that's the canonical Swift pattern an adopter will use — wrapping the subscriber Task in `MainActorOwnedWork` would teach a parent-project pattern that isn't part of the AudioIO public surface and would mislead readers.

**Process learning surfaced:**

1. **macOS code signing for OSS samples.** The default `CODE_SIGN_STYLE: Automatic` triggers "Signing for X requires a development team" on macOS builds without an explicit `DEVELOPMENT_TEAM`. iOS Simulator builds don't have this requirement. The portable answer is `CODE_SIGN_STYLE: Manual` + `CODE_SIGN_IDENTITY: "-"`, which is the ad-hoc "Sign to Run Locally" identity and works on both platforms without a team. Documented this in the sample's README so adopters can override for distribution.

2. **`@MainActor deinit` is mandatory for `@MainActor`-isolated classes that touch MainActor state in cleanup.** Swift 6.2 doesn't infer `deinit`'s isolation from the enclosing class's `@MainActor` — the default is nonisolated. A `deinit` body that references stored properties of an `@MainActor` class needs an explicit `@MainActor` annotation. This matches the pattern the app package's `PlaybackCoordinator` already uses; worth noting because the iOS Simulator build was the first place this error surfaced (SourceKit's inline diagnostic flagged it earlier but I'd written the cleanup body before noticing).

3. **`Color.red` vs `.red` in SwiftUI ternary expressions.** `Image.foregroundStyle(condition ? .secondary : .red)` fails because `.secondary` is `HierarchicalShapeStyle` and `.red` is `Color` — the ternary can't unify them. Either branch needs to be explicit (e.g., `Color.secondary` to coerce both to `Color`). Mildly surprising; documented here so the next sample-writer doesn't burn time on it.

Validation: iOS Simulator build clean (`xcodebuild build -project AudioIODemo.xcodeproj -scheme AudioIODemo -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`), macOS build clean (`-destination 'platform=macOS'`). Parent AIO + the app package tests unaffected (186/186, 1175/1175). All CI guards pass; async-usage ratchet shows the +3 task openings from the sample under control via the allowlist addition.

### 2026-05-27 — M3 (DocC): externally-focused catalog rewrite

Replaced the 10-file inside-baseball DocC catalog (which mostly contained internal architecture notes, navigation stubs, and spec docs written for the in-tree developer) with a 10-file externally-focused catalog organized around what an outside reader actually does: get started, understand the threading and error model, and reach for per-surface reference docs.

**Deleted (10 files, 681 lines):**

| File | Why dropped |
|---|---|
| `AIO.md` | Pointed at the SPEC files. Replaced with a new landing page. |
| `Architecture.md` | Listed internal target names — useful for contributors, irrelevant for adopters. |
| `Development.md` | CI-reproduction hints. Belongs in CONTRIBUTING, not the public catalog. |
| `Features.md` | Navigation-only stub. |
| `README.md` (DocC) | 10-line stub pointing at the SPECs. |
| `SPEC_AIO.md` | Useful Recording / Playback / Visualization content; refactored into Recording.md / Playback.md / AudioSession.md / Visualization.md / Events.md. |
| `SPEC_AUDIO_VIZ.md` | Consolidated into Visualization.md. |
| `MultiBandLODContract.md` | Consolidated into Visualization.md's LOD data contract section. |
| `MultiBandVisualization.md` | Consolidated into Visualization.md. |
| `core-audio-layer-opportunities.md` | Internal forward-looking architecture musing. Dropped entirely (no replacement in `docs/architecture/` — content was speculative). |

**Written (10 files, 769 lines):**

| File | Audience-first framing |
|---|---|
| `AIO.md` | Landing page with topic + surface navigation. States the prerelease status up front. Catalog root via `@TechnologyRoot`. |
| `GettingStarted.md` | Add-the-package, record/play/observe in one snippet, links to required-reading topics. Subscribes to `events` *before* driving the engine so the snippet doesn't model a race. |
| `PlatformMatrix.md` | iOS 26+ / macOS 26+. Tables for what's iOS-only, macOS-only, and symmetric. CI gate table at the bottom. |
| `ThreadingModel.md` | The five-domain ASCII diagram lifted from `AIOEngine.swift`'s in-source comment, plus per-API isolation tables (`@MainActor` vs `nonisolated`), broadcaster delivery semantics, and realtime-callback hygiene. |
| `ErrorHandling.md` | The two failure paths (typed throws vs `events.error`), the three domain enums and their cross-domain wrapping via `.session(_:)`, with read patterns for both branches. |
| `Events.md` | Lifecycle case-by-case with "when" descriptions, migration recipe for the deleted `on*` closures, multi-consumer subscription semantics. |
| `Recording.md` | Configuration + channel matrix + drive-the-engine + segmented rotation + reconciliation SPI escape hatch. |
| `Playback.md` | Whole-file vs segment time coordinates, scrub semantics, the `playbackStateChanged` vs `playbackUpdated` design intent. |
| `AudioSession.md` | What `AudioEnvironmentManager` owns, fan-out subscriber pattern, narrow protocol contracts, interruption interplay with recording. |
| `Visualization.md` | Subscriber-demand model, LOD data contract, frequency analyzer + beat detection details, offline LOD extraction. |

**Authoring choices worth carrying forward:**

1. **Topics vs reference split.** The five "concept topics" (Getting Started, Platform Matrix, Threading Model, Error Handling, Events) are prose-light and aimed at a first-read. The four "API surface" reference docs (Recording, Playback, Audio Session, Visualization) are denser, have `## Topics` sections enumerating the relevant symbols, and link into the auto-generated symbol pages. The landing page navigation reflects the split.
2. **Lead with what changes the reader's mental model.** Every page opens with a single sentence stating the contract the rest of the page elaborates. E.g., Events.md opens with "Subscribe once; pattern-match on the case you care about" — that's the entire mental model in 8 words.
3. **State the prerelease status up front.** The landing page calls out `0.x` semantics and the SemVer commitment at `1.0` so external readers don't reach for a version-pinning anti-pattern by accident.
4. **Symbol links over prose.** Where there's a documented symbol with a useful doc-comment, prefer ``\`AIOEngine/startRecording(configuration:)\``` over re-explaining the call. DocC renders the linked symbol's signature and doc inline.
5. **No internal-target listing.** The deleted `Architecture.md` listed 11 internal SwiftPM targets. From outside, that's just noise — adopters interact with three library products (`AudioIO`, `AudioSignals`, `Tools`), all surfaced on the landing page. Internal targets are an implementation detail.

**Validation:** AIO library builds clean (Swift compilation was unaffected — markdown-only change). DocC build verification deferred to the next CI run; symbol links were spot-checked against the actual API surface (BeatDetectionConfiguration statics, AudioVisualizationEngine.Configuration presets, AIOEngine nested-type paths) but a full DocC compile may still emit warnings for `@_spi(Advanced)` symbol references that DocC doesn't surface by default.

### 2026-05-27 — M3 (visualization): flatten type homes and naming

Reorganized the visualization module to remove three concrete smells: a redundant subdirectory, duplicate filenames across modules, and a cross-module split of subscriber-demand types. Zero behavior change; zero call-site changes anywhere.

**Three smells, three moves:**

1. **Redundant subdirectory.** `Packages/AIO/Sources/AIOVisualization/Visualization/` held all 6 of the module's source files, mirroring the target name. Lifted all 6 files (`AudioVisualizationEngine`, `VisualizationHub`, `VisualizationProcessor`, `VisualizationMainDelivery`, `VisualizationDispatchTicker`, `VisualizationTypes`) up to `Packages/AIO/Sources/AIOVisualization/` and removed the empty subdirectory.

2. **Duplicate `VisualizationTypes.swift` filenames.** `AudioSignals/VisualizationTypes.swift` (581 lines, signal-domain data + analyzer configs + work types) and `AIOVisualization/VisualizationTypes.swift` (98 lines, events + subscription protocol stack) both existed, which broke navigation by filename. Resolved by splitting the AIOVisualization file into role-based files: `VisualizationEvent.swift` (`VisualizationEvent` enum + `VisualizationEventMask` option set) and `VisualizationSubscription.swift` (`VisualizationRequest` struct + `VisualizationSink` protocol + `VisualizationSubscription` class + `VisualizationDriving` protocol). Renamed `AudioSignals/VisualizationTypes.swift` to `VisualizationData.swift` since after the Work-types move (below) it contains only signal-domain data + analyzer configs.

3. **Cross-module split of subscriber-demand types.** `VisualizationWork`, `LODWork`, `AnalysisWork`, and `FrequencyDomainWork` lived in `AudioSignals` even though they describe *what a subscriber demands from the visualization engine* — a coordination concept tied to engine dispatch, not a signal-domain data concept. Moved all four (plus their `ValidationError` enums) to a new `AIOVisualization/VisualizationWork.swift`. `MultiBandLODConfiguration` correctly stays in `AudioSignals` (it's a pure signal-domain config consumed by both the live engine and `OfflineLODExtractor`). `Exports.swift` updated to point the 4 typealiases at `AIOVisualization` instead of `AudioSignals` and grouped them under the AIOVisualization re-exports MARK.

**Conceptual layer the move enforces:** `AudioSignals` is the *signal-domain* layer — data structures the UI displays (`TimeDomainData`, `FrequencyDomainData`, `BeatInfo`) and analyzer parameters (`FrequencyBucketMode`, `BeatDetectionConfiguration`, `MultiBandLODConfiguration`). `AIOVisualization` is the *engine* layer — what computation runs, in what order, for which subscribers. The `Work` types describe "what computation a subscriber demands," which is engine-coordination, not signal-domain.

**Zero consumer churn.** Every app package and AVC reference to the moved types flows through the `AudioIO` umbrella, which transparently re-points its typealiases to the new homes. No `import` line in any consumer needed to change. The app package `.build` directory needed a `rm -rf` to flush stale SwiftPM file-list caches after the file moves (SwiftPM cached the pre-move paths and reported "missing inputs" for the old locations even though the targets resolved correctly on the re-resolve).

**File touch count:** 10 git moves/creates/deletes within `Packages/AIO/Sources/`, 1 edit to `Packages/AIO/Sources/AudioIO/Exports.swift` (typealias rehoming), 2 doc updates (PROGRESS.md + ROADMAP.md).

Validation: AIO tests 186/186 pass on macOS host, the app package tests 1175/1175 pass on macOS host, host app builds clean on iOS Simulator, all 8 CI guards pass (`check-no-swiftui-combine-in-aio`, `check-structural-boundaries`, `check-prerelease-compatibility`, `check-theme-boundaries`, `check-dbqueue-boundaries`, `check-aio-shared-branching`, `check-async-usage-policy`, `check-architecture-debt`). Async-usage policy ratchet unchanged (no new task openings or stream bridges).

### 2026-05-27 — M3 (lifecycle): `events` stream subsumes the 8 `on*` closure callbacks

Completed the M2.1 follow-up: `AudioIOEvent` now carries every engine lifecycle case the old `on*` closure callbacks did, the closures themselves are deleted, and the app package `RecordingCrashTracking` chained-observer dance is replaced with a single events-stream subscriber.

**`AudioIOEvent` cases added (in `AIOEngineCore`):**
- `recordingStarted(url: URL, format: String)` — initial start + segment rotation.
- `recordingCompleted` — user-initiated stop.
- `recordingFailed` — engine-side failure (usually paired with an `.error(_)` event).
- `recordingInterruption(AIOEngine.RecordingInterruption)` — route change continuation, graceful stop, or interruption-driven stop.
- `reconciliationFailed(desiredRecording: Bool)` — fire only in the `@_spi(Advanced)` reconciliation flow.
- `playbackStateChanged(AIOEngine.Playback?)` — play/pause/stop transitions.
- `playbackUpdated(AIOEngine.Playback?)` — every observation including ticks.

**File move:** `AudioIOEvent.swift` relocated from `AIOAudioSession/Events/` to `AIOEngineCore/Events/`. The move was safe because no file in `AIOAudioSession` actually emits events (the M2.1 PROGRESS entry mis-attributed two emission sites to `AIOAudioSession` — those `AIOEngine+AudioSession.swift` sites live in `AIOEngineCore`, the filename is misleading). Moving the enum next to the engine that emits it unblocks `AIOEngine.RecordingInterruption` and `AIOEngine.Playback` payloads without a dep cycle. `Exports.swift` typealias moved from the AIOAudioSession block to the AIOEngineCore block.

**Surface removed (dead public API per prerelease policy):**
- `AIOEngine.onRecordingInterruption` (+ async signature).
- `AIOEngine.onRecordingStarted`, `onRecordingCompleted`, `onRecordingFailed`.
- `AIOEngine.onSegmentCompleted` — declared but never fired anywhere in the codebase; subsumed conceptually by `recordingStarted` (which fires on both initial start and rotation).
- `AIOEngine.onReconciliationFailed`.
- `AIOEngine.onPlaybackStateChanged`, `onPlaybackUpdated`.
- The "Handling Events" docc topic listing the seven `on*` symbols, replaced with two entries (`events`, `AudioIOEvent`).

**Consumer migrations:**
- `<app-package>/Composition/RecordingCrashTracking.swift` — the chained-observer trio (`onRecordingStarted/Completed/Failed`) became a single `Task` subscribing to `engine.events`. The `RecordingCrashTrackingHandle` now owns the task; `uninstall()` cancels and awaits the task's value. The `MainActorTaskRunner` + per-tracker-call `callbackTasks.run { ... }` indirection is gone — the events-loop can `await tracker.markRecording*()` directly because the loop body runs on MainActor and serialization is the correct semantics (DB state-machine transitions should be ordered, not concurrent).
- `<app-package>/Composition/CoreServicesIntegration.swift` — the `onRecordingFailed` / `onReconciliationFailed` closure assignments that called `recordingService.syncRecordingStateFromEngine()` were deleted. That sync logic moved into `RecordingService` itself, extending the existing `engineErrorTask` (renamed `engineEventTask`) loop to handle the `.recordingFailed` / `.reconciliationFailed` cases.
- `<app-package>/Composition/AppServicesIntegration.swift` — the `onRecordingInterruption` assignment in `installSceneEventBridges` became a supervised `work.supervise(priority: .userInitiated)` block subscribing to `engine.events`, structurally identical to the existing `errorManager.eventStream` subscriber a few lines below. `actionTasks.run { ... }` is wrapped in `await MainActor.run { ... }` because the supervised closure runs nonisolated.
- `<app-package>/Player/Player.swift` — the `onPlaybackStateChanged` / `onPlaybackUpdated` assignments became a `MainActorOwnedWork { for await event in engine.events { switch event { ... } } }`, appended to `setupTasks`. Cancellation flows through the existing `deinit` cleanup.

**Test migrations (AIO):**
- `RecordingEventProbe` (AIOPlatformIntegrationTests) and `RouteFaultProbe` (AIOEngineIntegrationTests) each gain a `bridge(to:)` helper that subscribes to `engine.events` and routes recording-lifecycle cases to the probe's existing `record(_:)` / `recordFailure()` methods. The helper does `await Task.yield()` after starting the subscriber task so the broadcaster registration completes before the caller drives the engine.
- All probe-snapshot assertions are now wrapped in `waitUntil(...)` predicates (or extended existing `waitUntil` predicates) — the events pipeline has unbounded delivery latency between `Subject.send` and the subscriber task observing, so a direct `probe.snapshot()` after an `await engine.handleRouteChange(...)` is racy. Closure callbacks fired synchronously and didn't have this race.
- 6 tests migrated (2 in AIOPlatformIntegrationTests, 4 in AIOEngineIntegrationTests). No test mock updates were needed because `RecordingDriving` already exposes `events`, not the deleted closures.

**Process learnings surfaced:**

1. **Swift enum-case shorthand inference doesn't chain through enum-of-enum payloads.** Pattern that fails:
   ```swift
   eventSubject.send(
     AudioIOEvent.recordingInterruption(.routeChangeContinuing(event: event, qualityChange: nil))
   )
   ```
   Error: "Cannot infer contextual base in reference to member 'routeChangeContinuing'." The outer case (`recordingInterruption`) expects `AIOEngine.RecordingInterruption`, but Swift won't propagate that context to the inner `.routeChangeContinuing` shorthand. Fix is to build the payload first with an explicit type, then pass:
   ```swift
   let interruption = RecordingInterruption.routeChangeContinuing(event: event, qualityChange: nil)
   eventSubject.send(AudioIOEvent.recordingInterruption(interruption))
   ```
   This matches the M2.1 PROGRESS note about `eventSubject.send(.error(error))` needing full qualification through `Subject<T>.send(_:)` — Swift's bidirectional type inference is more limited than it looks once enum cases nest. Standardizing on the build-then-send pattern at every emission site keeps the surface uniform.

2. **AsyncBroadcaster subscription has unbounded delivery latency.** `Subject.send(_:)` enqueues into the controller's upstream stream; the controller's own work task then fans out to subscriber continuations. There's no synchronous "all subscribers received this event" signal. The closure callback the migration replaces was fire-synchronously, so tests that called `probe.snapshot()` immediately after `await engine.handleRouteChange(...)` worked by accident. Migrated tests must use `waitUntil(...)` predicates that include probe state, not direct snapshot reads. Documented as the broadcaster's contract; not a bug. If a future use case truly needs synchronous delivery, the right move is a separate API, not changing this stream.

3. **Multi-consumer broadcaster eliminates the chained-observer workaround.** The original `RecordingCrashTracking.attachRecordingCrashTracking` did `let prev = engine.onRecordingStarted; engine.onRecordingStarted = { url, format in prev?(url, format); ...our work... }`. That pattern existed solely because the `on*` properties were single-owner. With multi-subscriber broadcasters, every consumer (`RecordingCrashTracking`, `RecordingService.engineEventTask`, `AppServicesIntegration` toast routing, `Player.swift`) subscribes independently. The chained-observer hand-off becomes obsolete — confirming the roadmap's argument that the gating concern resolves by virtue of changing the API shape.

**Async usage policy ratchet:** `task_openings 36 → 4`, `task_shapes 15 → 9`, `scheduler_primitives 27 → 22`, `stream_bridges 74 → 56` — the migration introduced 3 new `Task` openings (RecordingCrashTracking subscriber, Player's MainActorOwnedWork events subscriber, test bridge helpers) which the policy counts under named platform utilities, well under baseline.

Validation: AIO tests 186/186 pass on macOS host, the app package tests 1175/1175 pass on macOS host, host app builds clean on iOS Simulator (`xcodebuild build -workspace <app>.xcworkspace -scheme <app> -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`), all CI guards pass (`check-no-swiftui-combine-in-aio`, `check-structural-boundaries`, `check-prerelease-compatibility`, `check-async-usage-policy`, `check-theme-boundaries`, `check-dbqueue-boundaries`, `check-aio-shared-branching`). Architecture-debt ratchet auto-updated `docs/architecture/DEBT_BUDGET.md`.

### 2026-05-27 — M2.1: unified `events: AsyncBroadcaster<AudioIOEvent>` stream

Replaced the weakly-typed `errors: AsyncBroadcaster<any Error>` engine stream with a unified, typed `events: AsyncBroadcaster<AudioIOEvent>` stream that consumers subscribe to via `for await event in engine.events { ... }`.

**New type (in `AIOAudioSession`):**
```swift
public enum AudioIOEvent: Sendable {
  case error(any AudioIOError)
}
```

Currently a single case (`error`), but the enum exists *because* the open-source v0.1.0 surface needs a single canonical stream rather than a parallel ecosystem of `errors:`, `lifecycle:`, `playback:` per-subsystem broadcasters. The lifecycle event cases (`recordingStarted`, `recordingCompleted`, `recordingFailed`, `recordingInterruption`, `segmentCompleted`, `playbackUpdated`, etc.) are tracked as future work — they currently flow through the `on*` closure callbacks, whose chained-observer adoption pattern (`RecordingCrashTracking.attachRecordingCrashTracking`) makes a clean stream migration substantial enough to defer to M3.

**Renames (no compat aliases per prerelease policy):**
- `AIOEngine.errors: AsyncBroadcaster<any Error>` → `AIOEngine.events: AsyncBroadcaster<AudioIOEvent>`
- `RecordingDriving.errors` requirement → `RecordingDriving.events` requirement
- `package var errorSubject: Subject<any Error>` → `package var eventSubject: Subject<AudioIOEvent>`
- Internal `errorSubject.send(error)` sites (4 — two in `AIOAudioSession`, two in `AIORecording`) → `eventSubject.send(.error(error))`

**Consumer migration:**
- The app package `RecordingService.handleEngineError`: the `for await error in engine.errors { handle(error) }` loop became `for await event in engine.events { guard case .error(let error) = event else { continue }; handle(error) }`. The handler signature tightened from `(any Error)` to `(any AudioIOError)` — this surfaces a compile-time check that the engine emits only `AudioIOError`-conforming values, which matches the M2.2 contract.
- Three test mock implementations of `RecordingDriving` (FakeEngine variants in RecordingServiceTests, RecordingServiceStartSuccessTests, RecordingServiceSegmentRotationTests): `errorSubject: Subject<any Error>` → `eventSubject: Subject<AudioIOEvent>`, `errors` requirement → `events`.

**Process note: Swift type inference for shorthand enum cases**: `.send(.error(error))` failed to infer `AudioIOEvent` because the `Subject<T>.send(_:)` call site couldn't propagate the `T = AudioIOEvent` context through the `.shorthand`. The fix at both engine-side emission sites was to fully qualify as `eventSubject.send(AudioIOEvent.error(error))`. Cheap fix; surfaces only because Subject's generic context isn't transparent to enum-case shorthand resolution. Worth knowing for the future lifecycle-event cases.

**Scope deliberately not done in M2.1** (deferred):
- Adding lifecycle event cases (`recordingStarted/Completed/Failed/Interruption/Segment`, `playbackStateChanged/Updated`, `reconciliationFailed`). The cases would slot cleanly into the existing enum — but each requires (a) emission wiring at the 12+ internal callback-fire sites and (b) chained-observer migration in `RecordingCrashTracking` and `AppServicesIntegration.onRecordingInterruption`. That's a substantial second pass best executed once the OSS extraction is bedded in.
- SPI-gating the `on*` closure callbacks. Once events covers everything, the closures become legacy; deferring until they're truly redundant.

Validation: AIO tests 186/186 pass, the app package RecordingService tests 15/15 pass, both platforms build clean, all CI guards pass.

### 2026-05-27 — M2.3: canonical `startRecording` + SPI'd reconciliation

Established a single canonical recording-start API and demoted the reconciliation-mode entry points to `@_spi(Advanced)`.

**Surface changes:**
- `AIOEngine.startRecording(configuration:) async throws(RecordingError) -> URL` — now returns the recording URL on success (was `Void`). This is the canonical fail-fast start: one shot, returns immediately when the engine produces output, throws a typed `RecordingError` on failure.
- `AIOEngine.setDesiredRecordingState(_:configuration:)` → `@_spi(Advanced)`. The fire-and-forget desired-state primitive with background reconciliation retry.
- `AIOEngine.startRecordingWithReconciliation(configuration:) async -> Bool` → `@_spi(Advanced)`. The awaitable form of `setDesiredRecordingState`.
- `AIOEngine.consumeLastRecordingStartFailure() -> RecordingError?` → `@_spi(Advanced)`. Only meaningful in the reconciliation flow; the canonical `startRecording` returns errors directly.
- `RecordingDriving` protocol's three reconciliation methods → `@_spi(Advanced)`. Public protocol; SPI'd requirements.

**Surface removed (dead public API per prerelease policy):**
- `AIOEngine.stopRecordingWithReconciliation() async -> URL?` — declared but unused outside AIO itself.
- Underlying `RecordingRuntime.stopRecordingWithReconciliation()` — the only caller was the deleted public facade.

**Consumer migration:**
- The app package `RecordingService.swift` and three test mocks (`RecordingServiceTests`, `RecordingServiceStartSuccessTests`, `RecordingServiceSegmentRotationTests`) opted into `@_spi(Advanced) import AudioIO`. Their use of `setDesiredRecordingState` / `startRecordingWithReconciliation` is principled — the host app's UI keeps `wantsRecording` visible regardless of engine state, and the reconciliation retry handles the audio-session-not-yet-ready race on cold launch.

**Process learning surfaced:** `@_spi(Group)` propagation across modules has a more demanding plumbing pattern than I expected. The protocol requirement in `AudioIO` (`@_spi(Advanced) func setDesiredRecordingState`) and the concrete implementation in `AIORecording` (`@_spi(Advanced) public func setDesiredRecordingState`) both need the matching SPI annotation. But the conformance file (`extension AIOEngine: RecordingDriving {}` lives in AudioIO) also needs `@_spi(Advanced) import AIORecording` to see the SPI'd implementation during conformance checking — without it, the compiler reports "type 'AIOEngine' does not conform to protocol 'RecordingDriving'". Additionally, `AudioIO/Exports.swift`'s `@_exported import AIORecording` had to become `@_spi(Advanced) @_exported import AIORecording` to propagate the SPI'd surface through the umbrella. End-state: a consumer writing `@_spi(Advanced) import AudioIO` sees the SPI'd API; a consumer writing plain `import AudioIO` sees only the canonical entry points.

Touched 8 files (4 AIO sources, 1 the app package source, 3 test mocks). AIO tests 186/186, the app package RecordingService tests 15/15, both platforms build clean, all CI guards pass.

### 2026-05-27 — M2.2: split `AIOError` into per-domain enums

Replaced the monolithic `AIOEngine.AIOError` (nested enum, 17 mixed cases) with three top-level domain enums in `AIOAudioSession`, all conforming to a new `AudioIOError` marker protocol:

- **`SessionError`** — `notReady(details:)`, `operationFailed(operation:error:)`, `engineStartFailed(error:)`. Operation enum kept as `SessionError.Operation`.
- **`RecordingError`** — `notRecording`, `alreadyRecording`, `engineError`, `formatConversionFailed`, `hardwareNotSupported`, `invalidConfiguration(details:)`, `unsupportedChannelCount(requested:maximum:)`, `unsupportedEncodedSampleRate(...)`, `fileFailed(operation:url:error:)`, `session(SessionError)`. Recording-side file ops kept as `RecordingError.FileOperation = {openForWriting, write}`.
- **`PlaybackError`** — `cannotPlayWhileRecording`, `invalidScrubTime(value:)`, `invalidTimeRange`, `fileReadFailed(url:error:)`, `session(SessionError)`.

**Cross-domain wrapping** via `.session(_:)` cases lets recording/playback code surface a session failure without losing its category — e.g. `RecordingError.session(.engineStartFailed(error:))` when AVAudioEngine fails to start during recording bring-up.

**Renames during the split** (no compat aliases per prerelease policy):
- `audioSessionFailed(operation:error:)` → `SessionError.operationFailed(operation:error:)`
- `audioSessionNotReady(details:)` → `SessionError.notReady(details:)`
- `AudioSessionOperation` → `SessionError.Operation`
- `invalidRecordingConfiguration(details:)` → `RecordingError.invalidConfiguration(details:)`
- `unsupportedRecordingChannelCount(requested:maximum:)` → `RecordingError.unsupportedChannelCount(requested:maximum:)`
- `audioFileFailed(operation:url:error:)` split into `RecordingError.fileFailed(operation:url:error:)` (write) and `PlaybackError.fileReadFailed(url:error:)` (read — operation enum dropped since reading has only one operation)
- `invalidScrubTime(details:)` → `PlaybackError.invalidScrubTime(value:)` (label was misleading; it was always the time value)
- `AudioFileOperation = {openForReading, openForWriting, write}` → `RecordingError.FileOperation = {openForWriting, write}` (read variant subsumed by `PlaybackError.fileReadFailed`)

**Dead surface removed**: `notPlaying` (never thrown), `invalidScrubTrack` (never thrown), `engineError` (case kept on `RecordingError` since tests fixture it). Also deleted dead internal `AIOError`/`AudioSessionError` in `AIOAudioSession/Env/Output/Error.swift` (declared but unused).

**Touched 18 files**: 4 new error files in `AIOAudioSession/Errors/`, 9 AIO source migrations (including the deletion of the nested `AIOError` from `AIOEngine.swift`), 4 AIO test migrations, 1 the app package consumer (`RecordingService.swift`), 3 the app package test mocks, 1 Exports.swift re-export, 1 deleted file.

**Three learnings surfaced during the split:**

1. **`@testable import` does NOT bypass `@_spi`** (rediscovered from M2.4). The test catch arms still needed the `@_spi(AVFoundation)` modifier — but in M2.2 the test code touches the new error types directly so this was a non-issue.

2. **Swift typed-throws can't always unify across an internal do-catch that wraps a different error type.** Pattern:

   ```swift
   do {
     try aSessionThrowingCall()         // throws SessionError
   } catch let e {                      // e inferred as `any Error`, not SessionError!
     throw RecordingError.session(e)    // compile error
   }
   ```

   The inner `catch` defaults to `any Error` binding. Two fixes work: typing the catch (`catch let e as SessionError`) or — preferred for whole-block clarity — typing the outer `do` with `do throws(RecordingError) { ... } catch { ... }`, which then propagates type information correctly. We used the `do throws(RecordingError)` form in `RecordingEngineRuntime.warm()` to let the outer catch's `error` be inferred as `RecordingError` cleanly. Documenting this in case future M2 work re-encounters it.

3. **Switch-as-expression doesn't compose with multi-statement branches.** First draft of `RecordingError.errorDescription` mixed short `case .x: "..."` branches with one `case .y(let a, let b): let computed = ...; return "..."` branch. The compiler rejected the short branches as "unused string literals" because the presence of the multi-statement branch demotes the whole switch from expression form to statement form. Fix: explicit `return` on every branch. Future cases here should pick a style and stick with it; mixing forms is the trap.

**Process learning surfaced (M2.5 lesson held)**: macOS SwiftPM tests passed but iOS Simulator build caught one more `.invalidRecordingConfiguration` reference in `AIOEngine+Testing.swift` line 225 — gated by `#if os(iOS)` inside the test scaffolding so the macOS build never compiled it. iOS Simulator is genuinely non-optional for any API-shape change.

Validation: AIO tests 186/186 pass, the app package RecordingService tests 15/15 pass, the app package builds clean on macOS via SwiftPM, host app builds clean on iOS Simulator. All CI guards pass (including the async-usage policy ratchet which now reports task_openings down from 36 → 1, scheduler primitives 27 → 20, stream bridges 74 → 56 vs baseline).

### 2026-05-27 — M2.4: `@_spi(AVFoundation)` escape hatches

Replaced dual `avAudio`/`platform` accessors on `AudioInput` and `AudioSource` with single `@_spi(AVFoundation)`-gated `avAudio` accessors. Extended the same SPI gating to the AV-taking initializers and to `PolarPattern.avAudio`. Renamed `EncodingQuality.platform` → `.avAudio` (also SPI-gated) for naming consistency with the other escape hatches.

**Surface narrowing (now SPI-gated; previously public):**
- `AudioInput.init(port:)` — only constructor; mainstream consumers receive `AudioInput` values via `AudioEnvironmentConfiguring.availableInputs`.
- `AudioInput.avAudio` — drops to underlying `AVAudioSessionPortDescription`.
- `AudioSource.init(avAudio:)` — explicit memberwise init (was implicit) to allow same-module factory access.
- `AudioSource.avAudio` (stored let).
- `PolarPattern.init(avAudio:)` — explicit memberwise init.
- `PolarPattern.avAudio` (stored let).
- `EncodingQuality.avAudio` (formerly `.platform`).

**Surface removed entirely:**
- `AudioInput.platform` — verbatim duplicate of `.avAudio`.
- `AudioSource.platform` — verbatim duplicate of `.avAudio`.

**Touched 7 files** (3 sources gain SPI gates / rename; 3 internal call sites migrate from `.platform` → `.avAudio` purely within `AIOAudioSession`; 1 test gains `@_spi(AVFoundation) @testable import AIOAudioSession`).

**Process learning surfaced:** `@testable import` does NOT bypass `@_spi` gating — discovered when the test compile failed with `'avAudio' is inaccessible due to '@_spi' protection level` despite using `@testable import AIOAudioSession`. `@testable` elevates `internal` to visible, but `@_spi(name)` is a parallel access mechanism that requires the consumer to write `@_spi(name) import`. They compose: `@_spi(AVFoundation) @testable import …`. This is actually the right design — SPI is a contract about *intent*, so tests that exercise an escape hatch should opt in explicitly.

**Zero external consumers affected.** Pre-edit `grep` confirmed the app package references `AudioInput`/`AudioSource`/`PolarPattern` only via mainstream API (`.name`, `.id`, `.supportedPolarPatterns`, `.tag(nil as AudioInput?)`, etc.). No `.platform` / `.avAudio` / direct-init call sites existed outside AIO itself.

Validation: AIO tests 186/186 pass, the app package builds clean on macOS via SwiftPM, host app builds clean on iOS Simulator. All structural / prerelease / SwiftUI-in-AIO guards pass.

### 2026-05-27 — M2.5: SampleRate redesign

Replaced the `SampleRate.Common.sr44100` enum-based API with `ExpressibleByIntegerLiteral` + named statics (`.cd`, `.dvd`, `.hiRes96`, `.hiRes192`) and a `static let common: [SampleRate]` array for UI selectors.

Removed surface: `RawRepresentable` conformance, `enum Common`, `init(common:)`, `static func common(_:)`, `static var commonCases`, `var platform`. Replaced `rawValue: Double` with `let hz: Double`.

Touched 30 files (SampleRate.swift + 29 consumers across AIO internals, tests, the app package, docs, harness). Code reviewer caught 1 CRITICAL (7 missed `.rawValue` references inside `#if os(iOS)` code that `xcrun swift test --package-path Packages/AIO` couldn't see — fixed) and 2 MEDIUMs (renamed `.studio96k`/`.studio192k` → `.hiRes96`/`.hiRes192` for consistency with `.cd`/`.dvd` medium-naming pattern; added `32_000` to `common` array for FM broadcast / MPEG-1 use cases). Documented `Codable` keyed-container shape in type comment.

**Process learning surfaced:** `xcrun swift test --package-path Packages/AIO` runs on macOS host and silently skips `#if os(iOS)` and `#if canImport(UIKit)` code paths. Any M2+ commit that touches API shape needs an iOS Simulator build (`xcodebuild build -workspace <app>.xcworkspace -scheme AIOiOSTests -destination 'platform=iOS Simulator,...'`) to validate iOS-conditional code, not just SwiftPM tests. The first iOS validation run since M1.1a also surfaced that `<app>.xcodeproj` was never regenerated after M1.1a's `project.yml` rename (`.xcodeproj` is gitignored so `git status` was silent on it) — fixed by running `xcodegen generate`.

Bonus M1.1b cleanup landed in the same commit: `RecordingActivityManager.swift` had `import AudioIO` (resolved as `internal` under `InternalImportsByDefault`) while exposing `TimeDomainData` in a `public func` parameter. Promoted to `public import AudioIO`. Similar promotions in `ConfigurationView.swift` and `RecordingSheetView.swift` for symmetry.

Validation: AIO tests 186/186 pass, the app package builds clean on macOS via SwiftPM, all CI guards pass. iOS Simulator build now clean too after the M1 follow-up below.

### 2026-05-27 — M1 follow-up: iOS InputPicker generic-constraint regression fixed

The M2.5 iOS validation run surfaced a pre-existing M1.1b regression: `ConfigurationView`, `RecordingSheetView`, and `RecordingView` were all generic over `AudioEnv: AudioEnvironmentConfiguring`, but on iOS they invoke `InputPicker` which requires the stronger `AudioInputPickingEnvironment` constraint. The mismatch was invisible to `xcrun swift test` (macOS host, iOS-only `InputPicker` doesn't compile) but blocked iOS Simulator builds.

**Fix:** added a macOS `typealias AudioInputPickingEnvironment = AudioEnvironmentConfiguring` in `RuntimeDriving.swift`, then tightened the generic constraint on all three views to `AudioInputPickingEnvironment`. On iOS, the typealias resolves to the stricter protocol with the `session: AVAudioSession` member; on macOS, it aliases the weaker protocol that the iOS-only `InputPicker` doesn't reference. Three-file diff plus the typealias.

Also bundled in the same iOS validation pass: discovered that `<app>.xcodeproj` had been stale since M1.1a's `project.yml` rename (the xcodeproj is gitignored, so SwiftPM-only validation never noticed). Ran `xcodegen generate` to refresh.

iOS Simulator build now clean. M1 milestone exit criteria are *actually* satisfied now (not just on macOS).

### 2026-05-27 — M1.2: access-level audit completed (0 demotions in scoped modules)

Audited every top-level `public` symbol in the 3 modules on `public import` from AudioIO (`AIOAudioSession`, `AIOContracts`, `AIOEngineCore`) against the typealias list in `Exports.swift`. Result: every public symbol is either typealiased (intentionally kept public) or rides along as a nested member of a typealiased parent. **Zero demotions to apply.**

This is actually evidence that M1.1b was thorough: by curating the typealias list carefully against the corrected public-symbol audit, M1.1b set the floor where every public top-level symbol in those modules has a documented reason to be public. Nothing's leaking accidentally.

**Scope note:** the 5 modules still on `@_exported import` (`AIOMicHealth`, `AIOVisualization`, `AudioSignals`, `AIOPlayback`, `AIORecording`) export their entire public surface wholesale by definition, so they don't have "accidental" leaks — they have an *intentionally broad surface* that's grandfathered until a future pass extends M1.1b's typealias treatment to them. That pass is deferred post-`0.1.0` because it requires resolving the `MemberImportVisibility` constraints documented in the M1.1b surprises section.

One small follow-up surfaced: `PlatformChannel` (a `public typealias` in `AIOAudioSession/Input/AudioChannel.swift`) is the only non-typealiased top-level public symbol in scope. It's used only within its own file, but its retroactive Hashable conformance contains `public static func ==` / `public func hash(into:)` whose parameters reference `PlatformChannel` — demoting the typealias would require also demoting those methods, which is out of scope for this pass (M1.2 explicitly avoided member-level demotions). Defer for a focused extension-visibility audit.

Validation: AIO tests 186/186, the app package build clean, all guard scripts pass. Working tree was clean post-iteration (1 attempted demotion of `PlatformChannel`, reverted).

### 2026-05-27 — M1: surface narrowing complete

M1 milestone exit criteria satisfied:
- ✅ One curated public product (`AudioIO`) — M1.1a
- ✅ No `@_exported import` of internal targets for the demotable-without-MemberImportVisibility-friction modules (3 of 8) — M1.1b
- ✅ Explicit typealias re-export list in `Exports.swift` + `PublicAPISnapshot.swift` canary — M1.1b
- ✅ Zero `import SwiftUI` / `import Combine` in `Packages/AIO/Sources/` — M1.3
- ✅ CI guards: `check-no-swiftui-combine-in-aio.sh`, `check-async-usage-policy.sh`, existing structural-boundary scripts — all green
- ✅ Access-level audit: 0 demotion opportunities found in scoped modules; deferral scope documented — M1.2

The 5 modules still on `@_exported import` are documented inline in `Exports.swift` with the specific blockers preventing demotion (extension methods, MemberImportVisibility for instance methods/initializers/static members). Those are tracked as future work, NOT M1 exit-criteria gates.

**Ready to extract.** Next move (whenever the user is ready): `git filter-repo` the `Packages/AIO/` subtree into the new `swift-audio-io` repo, drop in the foundational docs from `docs/aio-extraction/`, tag `v0.1.0`, push.

### 2026-05-27 — M1.3: SwiftUI/Combine stripped from AIO

Removed 4 import lines from `Packages/AIO/Sources/`:
- `ErrorManager.swift`: `public import SwiftUI` (the trailing `EnvironmentValues.errorManager` extension moved to the app package).
- `AudioEnvironmentManager.swift`: `import Combine` (verified dead — no Combine APIs were referenced).
- `OrientationObserver.swift`: `import Combine` and `import SwiftUI` (the latter was also dead; Combine was load-bearing for `NotificationCenter.publisher(for:).sink`).

`OrientationObserver.stream()` rewritten from a Combine-based pipeline to the package's established `AsyncSignal + AsyncTaskRunner + terminationHandler` pattern, matching `PlatformAudioBackend.swift`'s `routeChanges()`. Two `AsyncTaskRunner`s (observer + termination) replace what would otherwise be two raw `Task` openings.

New app package file: `Sources/Waveforms/Interface/EnvironmentValues+ErrorManager.swift`. Placed in `WaveformInterface` (not `AppTarget`, as originally planned) because `MetalClipWaveformThumbnailView` in the `WaveformMetal` target also reads `@Environment(\.errorManager)`; `WaveformInterface` is the lowest dep-graph ancestor of both consumers.

New CI guard: `bin/check-no-swiftui-combine-in-aio.sh` plus a `prek.toml` hook entry. The grep pattern catches `public`, `internal`, `package`, and `@_exported` import-visibility prefixes against `SwiftUI` and `Combine`.

Validation: AIO tests 186/186, the app package build clean, `check-async-usage-policy.sh` ratchet passes (`task_openings: 1` vs baseline 36 — net reduction).

Reviewer caught 1 HIGH (the executor's initial implementation used raw `Task { @MainActor in ... }` inside `cont.onTermination`, reverting the established `AsyncTaskRunner` pattern) + 1 LOW (the guard regex missed `package import` visibility). Both addressed.

### 2026-05-27 — M1.1b: explicit-facade rewrite landed

Replaced `@_exported import` wholesale module re-exports in `Exports.swift` with curated `public typealias` declarations for ~70 top-level public symbols. Added `Tests/AIOTests/PublicAPISnapshot.swift` as the compile-time canary for the public API.

The original spec called for 6 modules demoted to `internal import` + 2 retained on `@_exported import`. Reality:
- 3 modules demoted to `public import` (`AIOAudioSession`, `AIOContracts`, `AIOEngineCore`).
- 5 modules retained on `@_exported import` (`AIOPlayback`, `AIORecording`, `AIOMicHealth`, `AIOVisualization`, `AudioSignals`).

The expanded asymmetry surfaced from the iterative compile loop: Swift 6's `MemberImportVisibility` upcoming feature blocks more than just extension methods — it also blocks consumers from calling instance methods, initializers, and static members through a transitive `public import`. Any module whose `public` callable surface is touched by the app package needs to stay on `@_exported import` until the call sites are migrated behind a protocol contract.

Test count: 180 → 186 (6 new snapshot tests, one per source module).

Reviewer caught 2 documentation gaps (MemberImportVisibility asymmetry for AIOAudioSession is not fully justified; OfflineLODExtractor exclusion comment was scoped too narrowly to one consumer) and 1 missing canary (`MultiBandLODProcessor.LODGenerationError` is a nested enum used in `throws(...)` clauses). All addressed.

### 2026-05-27 — M1.1a: `AIOEngine` → `AudioIO` rename landed

Mechanical rename of the umbrella product/target. 134 files modified (5 git renames, 3 `Package.swift` files, `project.yml`, 1 OSLog subsystem string, 129 Swift `import` statements). The Swift *class* `AIOEngine` (in `AIOEngineCore`) and all internal target names were intentionally preserved.

Validation: AIO SwiftPM tests pass (180/180 in 0.62s). The app package SwiftPM build succeeds (491 modules, 22s).

Sub-agent workflow: 2 discovery agents (parallel), 1 execution agent, 1 code-reviewer agent. The discovery agents found one important fact the prior summary missed — the app package has zero direct imports of internal AIO targets (e.g., `AIOAudioSession`). The umbrella has held, which made the rename a single-name find/replace operation.

Doc reconciliation: README, AGENTS.md (symlinked from CLAUDE.md), DocC catalog, and slash-command descriptions updated to reflect `AudioIO` as the product name. Class-name references (`AIOEngine` the Swift class, `AIOEngine/AIOError` DocC paths, `AIOEngine+Recording.swift` source file) were intentionally kept.

### 2026-05-27 — Phase 0 foundational docs drafted

Staged in `docs/aio-extraction/`:
- `README.md` (3.6 KB) — repo-front pitch with `0.1.0` install + `1.0` aspirational example.
- `LICENSE` (Apache-2.0, verbatim, `Copyright 2026 GoodHats LLC`).
- `CONTRIBUTING.md` — dev setup, PR conventions, `@_spi` stability tier callout.
- `NOT_AUDIO_IO.md` — explicit non-scope list. Recording/playback framing; transcription/LLM omitted as obviously out-of-domain rather than defensively listed.
- `ROADMAP.md` — M1/M2/M3 milestones, stability commitments, "Now/Next/Later/Not" framing.

Phase 0 decisions locked: module name `AudioIO`, repo `GoodHatsLLC/swift-audio-io`, Apache-2.0, single public product, `Tools` and `AudioSignals` absorbed as SPIs, no SwiftUI in library, AVC extraction deferred post-1.0.

<!-- done-log:end -->

## Surprises and open issues

<!-- surprises:start -->

### 2026-05-27 — Discovery agent missed indented `public` decls

The first public-symbol discovery agent reported "0 top-level public decls" for `AIOPlayback`, `AIORecording`, `AIOVisualization`, `AIORecordingSupport`, and `AIOSupport`. Verification proved this wrong for the first three.

**Root cause:** the agent used a `^public ` regex (column-1 anchored). Many AIO source files wrap their bodies in `#if canImport(AVFoundation)` blocks, indenting public declarations by 2+ spaces. The regex silently skipped them.

**Actual surface (re-audited with `^\s*public\s+`):**
- `AIOVisualization` exposes `AudioVisualizationEngine` (class), `VisualizationSink` / `VisualizationDriving` (protocols), `VisualizationSubscription` (class), and ~30 lines of public surface.
- `AIOPlayback` exposes 8 `public func` extensions on `AIOEngine` (no top-level types).
- `AIORecording` exposes 8 `public func` extensions on `AIOEngine` + 1 typealias.
- `AIOAudioSession` is much wider than reported: `SampleRate`, `AudioChannel`, `AudioInput`, `AudioSource`, `ChannelCount`, `AudioEnvironmentManager`, plus a macOS variant of `AudioInput` and `AudioEnvironmentManager`.
- `AudioSignals` includes `MultiBandLODProcessor`, `MultiBandLODSnapshot`, `LODSnapshotRef`, `AmplitudeAnalyzer`, `FrequencyAnalyzer`, etc. — far beyond the 3 the agent named.

**Net effect on plan:** the public surface is much bigger than the agent suggested, so the explicit-facade rewrite (replacing `@_exported import` with curated `public typealias` declarations) is a larger curation task than estimated. We're splitting M1.1 into M1.1a (rename only) and M1.1b (facade rewrite) so we get a green-build checkpoint between them.

**Process learning:** any future Swift public-API audits in this codebase should use `grep -E '^\s*public\s+'` (or `swift symbolgraph-extract`), not column-1 anchored patterns. Worth encoding as a comment in CONTRIBUTING.md eventually.

### 2026-05-27 — swift-format re-sorted 84 import blocks after the rename

The pre-commit `swift-format` hook re-sorted import statements in 84 files because `AudioIO` sorts alphabetically *after* `AppModels`, whereas `AIOEngine` sorted *before*. Each affected file lost its `AudioIO` import from its old position and gained it lower in the block.

**Net effect on diff:** the M1.1a commit grew by 84 net-zero hunks. No semantic change; every file remained green.

**Process learning:** future mass renames of import targets should anticipate alphabetical-sort fallout. The cost is purely diff-size, not behavior, but it's worth knowing so the second-pass swift-format hook doesn't surprise the executor agent.

### 2026-05-27 — `MemberImportVisibility` is wider than just extension methods

The M1.1b plan assumed "modules with extension methods on AIOEngine need `@_exported import`; everything else can be demoted." Reality (discovered by the executor agent's iterative compile loop): Swift 6.3's `MemberImportVisibility` upcoming feature also blocks consumers from calling **instance methods**, **initializers**, and **static members** on types from a module that's only available via transitive `public import`.

Concretely: the app package's `LiveLevelPublisher` calls `MicHealthMonitor(...)` (initializer + instance methods). Under `public import AIOMicHealth` (not `@_exported`), app package call sites fail to compile with "method/initializer is not accessible from this module." Same for several app package call sites against `AudioVisualizationEngine` and `AudioSignals` types.

**Net effect:** 5 of 8 modules ended up retaining `@_exported import`, only 3 could be safely demoted to `public import`. The typealiases are still load-bearing — they're the curated surface canary even on modules using `@_exported`.

**The migration path** to a fully `internal import`-only Exports.swift requires either:
1. Moving the called methods into the AudioIO target itself (the strategy already used for `AIOEngine+Interruptions`, `AIOEngine+Testing`), or
2. Defining narrow protocol contracts inside AudioIO (the pattern already in place for `AudioEnvironmentDriving`, `RecordingDriving`, etc.) and having app-package code call through the protocol contracts, never directly against the concrete type.

The asymmetry between AIOAudioSession (demoted to `public import`) and AIOMicHealth/AIOVisualization/AudioSignals (kept `@_exported`) is currently empirical: AIOAudioSession's hot paths happen to flow through the `AudioEnvironmentDriving` protocol contract, so MemberImportVisibility never trips. Stricter future enforcement could push AIOAudioSession back onto `@_exported`. Documented inline in `Exports.swift`.

### 2026-05-27 — `OfflineLODExtractor` typealias would have broken the build

The executor agent attempted to typealias `OfflineLODExtractor` and `OfflineLODResult` in `Exports.swift`. The app package's `MetalClipWaveformThumbnailView` declares a `package init` whose parameter type is `OfflineLODExtractor.ChannelStrategy`, while the file does both `import AudioIO` (default `internal`) and `package import AudioSignals`. Introducing the typealias caused Swift to resolve the reference through the `internal`-imported alias path, triggering an access-level mismatch because the type was reached at `internal` access but used in a `package` API surface.

Resolution: don't typealias those two types. The underlying types remain reachable via the `@_exported import AudioSignals` line.

**Process learning:** when a typealias path coexists with a direct `package import` of the same module in any consumer, Swift prefers the lower-access path. The consumer's existing `package import` is the right resolution path; the new typealias would just confuse the resolver. Watch for similar dual-import patterns in future M1 sub-steps.

<!-- surprises:end -->

## Conventions

- Dates use ISO `YYYY-MM-DD`.
- One "Done" entry per substep that landed. Bullet points, no long prose.
- "Surprises" entries describe non-obvious findings — things that *changed our plan* mid-flight. Routine work doesn't belong here.
- When a milestone exits, move its "Currently in flight" block down to "Done" with a one-line summary and a link to the PR(s).
