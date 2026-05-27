# What AudioIO is not

AudioIO is the audio I/O layer of an app. It deliberately stops at recording, playback, level-of-detail visualization data, and mic-health monitoring. This document lists what's out of scope and why, so contributors don't have to guess.

If you want one of the things on this list, that's fine — open a Discussion, not an issue, and link to anywhere that solves the problem today. We're happy to point you to alternatives.

## Out of scope

### UI, SwiftUI, and Combine

AudioIO ships zero `import SwiftUI` and zero `import Combine`. No `@Environment` extensions, no `@Published` properties, no `ObservableObject` conformances.

**Why:** UI frameworks ratchet onto APIs in ways that are hard to undo. A library that exports `EnvironmentValues.audioEngine` is an effectively-SwiftUI library, even if its core has nothing to do with rendering. We keep the engine UI-agnostic so it composes with SwiftUI, UIKit, AppKit, or none of the above. `@Observable` (from the `Observation` framework, not SwiftUI) *is* used internally and exposed where appropriate.

**Where to find it:** the [`Examples/AudioIODemo`](Examples/AudioIODemo) sample app shows the ~15 lines of glue code to wire AudioIO into a SwiftUI app.

### Waveform views and rendering

No `WaveformView`, no `WaveformShape`, no Metal renderers. AudioIO exports the *data* needed to render waveforms (multi-band LOD snapshots) but never the views themselves.

**Why:** rendering choices (canvas vs metal vs raster, color, animation policy, hit-testing) are application concerns. A library that ships waveform views forces every consumer to inherit those choices.

**Where to find it:** Recorder‽'s `AVC` package contains a SwiftUI implementation; a standalone `swift-audio-io-views` repo is a candidate post-1.0 deliverable. See [ROADMAP.md](ROADMAP.md).

### Audio effects, DSP, and signal processing

AudioIO includes basic mixer amplitude and the LOD analysis needed for visualization. It does not include reverb, EQ, compression, pitch shifting, time stretching, or other effects, even though Recorder‽ uses these internally.

**Why:** effects libraries are a different shape of project — they live in chains, they accumulate parameters over years, and their API stability requirements diverge from an I/O engine's. They also have a thriving ecosystem already.

**Where to find it:** `AVAudioEngine`'s built-in nodes (`AVAudioUnitReverb`, `AVAudioUnitEQ`, etc.), `AudioKit`, or specialized DSP libraries.

### Editing, mixing, timelines, clips

AudioIO records to a file. It does not provide multi-track editing, clip arrangement, lane management, gain automation, or any of the non-linear-editor features.

**Why:** these are application features built *on top* of an I/O engine, not part of it. Recorder‽'s own editor lives in `AppLibrary`, not in `AIO`.

**Where to find it:** application code. The Recorder‽ codebase has an open-source-friendly editor implementation; ask if you want to use it.

### Network streaming, HLS, WebRTC, AirPlay

AudioIO reads and writes local files. It does not stream over the network.

**Why:** network audio is a different problem domain with its own concurrency, codec, and protocol concerns.

**Where to find it:** Apple's `AVPlayer`, `HLS.js`-style libraries, WebRTC stacks, or AirPlay APIs (`AVRoutePickerView`).

### Background tasks, BGTaskScheduler integration, Live Activities

AudioIO recording works in the background when the host app declares the appropriate `UIBackgroundModes`. The library does not register background tasks, schedule activities, or interact with Live Activity widgets — those are app-shell concerns.

**Why:** background task scheduling depends on app entitlements, lifecycle, and product decisions that the engine can't know.

**Where to find it:** application code; Apple's `BackgroundTasks` and `ActivityKit` frameworks.

### Cloud sync, iCloud, file-provider integration

AudioIO writes files to URLs you give it. It does not know or care whether those URLs are on iCloud Drive, in a security-scoped resource, in a temporary directory, or anywhere else.

**Why:** persistence and sync are application choices.

**Where to find it:** `NSFileCoordinator`, `URLSession` for upload, `FileProvider` framework, vendor SDKs.

### Telemetry, analytics, crash reporting

AudioIO emits structured events through its `events` AsyncStream. It does not phone home, log to vendor analytics, or report crashes.

**Why:** observability is an application concern. Consumers subscribe to events and forward what they care about.

**Where to find it:** any analytics or telemetry SDK consumed by your application.

### Format conversion as a general tool

AudioIO can record to a limited, curated set of output formats (CAF, WAV, AIFF, AAC, ADTS, FLAC). It is not a general transcoding library — there's no "convert MP3 to WAV" entry point.

**Why:** transcoding crosses the boundary into media tooling territory.

**Where to find it:** `AVAssetExportSession`, `ffmpeg`-based libraries.

### Other Apple platforms (tvOS, watchOS, visionOS)

Not currently supported.

**Why:** we don't run on them and can't validate that our `AVAudioSession` assumptions hold. PRs that add support are welcome but must include CI coverage.

## The "spirit of the rules"

The single sentence that decides whether something belongs in AudioIO:

> Could a non-Recorder‽ app use this without inheriting a UI choice or a product opinion?

If yes, it might belong. If no, it doesn't.
