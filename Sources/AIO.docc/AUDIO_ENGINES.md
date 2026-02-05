# Audio Engine Graphs in Recorder‽

This repo currently ships multiple `AVAudioEngine`-based graphs. Two of them implement the **project mixing** feature set (realtime playback vs offline export), and another graph implements **recording + simple track playback**.

This document summarizes:

- What each graph *is* (topology + scheduling model)
- What conceptual model would be required to consolidate them
- Whether consolidation is reasonable *for this project right now*
- What future value consolidation unlocks
- Implementation quality: reliability, efficiency, and notable risks

## Inventory (Where + Why)

### 1) Realtime project mixer

- File: `Packages/AppLibrary/Sources/AppTarget/Player/ProjectMixEngine.swift`
- Purpose: realtime playback for project editors (lane+clip gain, boosting > 0 dB, crossfades, live gain updates)
- Core idea: schedule all clip segments up-front and drive gain/crossfade updates from a host-time clock

### 2) Offline project renderer (export)

- File: `Packages/AppLibrary/Sources/AppTarget/Services/ProjectMixOfflineRenderer.swift`
- Purpose: render a project mix to a PCM file using `enableManualRenderingMode(.offline, …)` (for later AAC/M4A transcode)
- Core idea: schedule segments on the manual-rendering timeline and run a tight render loop that applies gain/crossfades per block

### 3) Recording + simple playback engine

- File: `Packages/AIO/Sources/AIOEngine/AIOEngine.swift`
- Purpose: microphone capture (with file writing + buffer receiver fan-out) and single-file playback/scrubbing
- Core idea: tap the input node, convert in-process, buffer into ring buffers, write from a non-real-time task

## What Each Graph Actually Looks Like

### ProjectMixEngine graph (realtime)

The node topology is essentially:

```
voice0.player -> voice0.eq -> laneMixer \
                                    -> laneEQ -> mainMixer -> (DynamicsProcessor limiter) -> output
voice1.player -> voice1.eq -> laneMixer /
```

Key points:

- There are **2 voices per lane** to support overlaps / crossfades without segment overlap on a single `AVAudioPlayerNode`.
- Lane gain is applied via `laneEQ.globalGain`.
- Clip gain and fades are applied via per-voice `eq.globalGain`.
- A master “limiter-ish” stage is inserted by instantiating Apple’s Dynamics Processor (`kAudioUnitSubType_DynamicsProcessor`) and wiring `mainMixer -> limiter -> output`.
- Scheduling model:
  - A single “anchor” host time is computed (Mach absolute time + 100ms).
  - Every clip is scheduled as an `AVAudioPlayerNode.scheduleSegment` at an `AVAudioTime(hostTime: …)` aligned to that anchor.
  - A 16ms timer updates:
    - `time` (best-effort UI clock)
    - discrete gain change events (clip boundaries / pre-roll starts)
    - fade envelopes (cos/sin equal-power crossfade curve, applied as stepped updates)

### ProjectMixOfflineRenderer graph (offline)

The topology matches `ProjectMixEngine` closely (same nodes, same limiter). Differences are mostly *execution*:

- The engine is put into manual rendering mode (`.offline`), with a fixed output format (48 kHz stereo).
- Scheduling model:
  - Each clip is scheduled with `scheduleSegment(... at: AVAudioTime(sampleTime: ..., atRate: outputSampleRate))`.
  - The renderer runs a `while engine.manualRenderingSampleTime < totalFrames` loop:
    - applies any gain events <= current time
    - applies any fades active at the current time
    - renders a block via `engine.renderOffline(...)`
    - writes PCM to an `AVAudioFile`
- Like the realtime mixer, it computes:
  - per-clip pre/post extensions to create handle-based crossfades (using `CrossfadePlanner`)
  - a 2-voice assignment plan per lane

### AIOEngine graph (recording + simple playback)

AIOEngine is a different “shape” than the project mixer.

- Recording path:
  - Installs a tap on `engine.inputNode` and receives buffers on the audio render thread.
  - Converts buffers to a chosen “processing” format in-process (with an `AVAudioConverter` cache).
  - Pushes float samples into per-channel `RingBuffer<Float>` instances.
  - A detached writer task flushes chunks from ring buffers into an `AVAudioFile`.
  - Buffer receivers (UI meters / waveform / analysis) are fed from channel 0 during capture.
- Playback path:
  - Attaches a single `AVAudioPlayerNode` and connects it directly to `engine.outputNode`.
  - Supports `scheduleFile`, `scheduleSegment`, and a simple “scrub” implementation that re-schedules from a new frame position.

Operationally, it also owns:

- audio session configuration (preferred sample rate, buffer duration, channel count)
- route change handling with “continue if possible” tap reinstall logic
- interruption handling + a reconciliation loop for transient failures (desired recording state vs actual)

## Consolidation: What Model Would Be Required?

There are two very different consolidation questions:

1) consolidate the **two project mix graphs** (realtime + offline)
2) consolidate the **project mixer** with **AIOEngine** (recording/simple playback)

They have very different costs and benefits.

### A) Consolidating realtime + offline project mixing (recommended scope)

To consolidate `ProjectMixEngine` and `ProjectMixOfflineRenderer`, the code needs to adopt a clearer separation between:

1. **Mix semantics (pure model)** — lanes, clips, gains, crossfades, and any other “editor semantics”.
2. **Mix plan (pure computed artifact)** — a deterministic schedule of:
   - per-voice segments (source frames + destination timeline placement)
   - gain events (voice gain at boundaries)
   - fade envelopes (equal-power curve parameters)
   - master chain configuration (limiter settings, output format expectations)
3. **Executor backend (impure, AVFoundation-specific)** — “play” the plan using either:
   - realtime host-time scheduling + periodic gain updates, or
   - manual offline rendering + block-by-block gain updates.

In other words: **“plan once, execute twice.”**

Concretely, a unified model would likely look like:

- `ProjectMixSession` (already exists twice with the same shape)
- `ProjectMixPlan` (new)
  - `lanes: [LanePlan]` where each lane has 2 `VoicePlan`s
  - `segments: [SegmentPlan]` keyed by lane/voice
  - `gainEvents: [GainEvent]` keyed by lane/voice
  - `fades: [FadeEvent]`
  - `startTime` / `renderRange` parameters (so offline rendering can later support partial exports and realtime can seek without rebuilding everything from scratch)
- `ProjectMixGraphBuilder` (new, AVFoundation-specific)
  - creates nodes, attaches/connects, configures limiter, exposes per-lane/voice handles
- `ProjectMixExecutor` protocol with two implementations:
  - `RealtimeMixExecutor` (host-time)
  - `OfflineMixExecutor` (manual rendering)

This scope is realistic because the two implementations already share:

- the same node topology (two voices per lane, lane mixer/EQ, master limiter)
- the same crossfade planning algorithm (`CrossfadePlanner`)
- the same fade curve (equal-power crossfade via cos/sin)

### B) Consolidating AIOEngine with project mixing (high risk / low short-term leverage)

To truly “consolidate” AIOEngine with the mix engine, the project would have to adopt a much broader conceptual model:

- a single **audio subsystem** that can switch between (or concurrently support):
  - capture (tap/input-driven)
  - simple playback (single file)
  - multi-lane playback (project mix)
  - offline rendering (manual rendering)
- explicit management of the engine’s **mode/state machine**:
  - which nodes are attached for each mode
  - what happens on transitions (stop/reset vs detach/reattach vs reuse)
  - who owns the audio session and how “mode switching” interacts with route changes

This is feasible in principle, but it is effectively a small audio platform rewrite: it forces shared lifecycle rules between a recording pipeline (real-time constraints + I/O + route resilience) and a multi-track playback pipeline (complex scheduling + dynamic gain automation).

## Is Consolidation Reasonable for This Repo Right Now?

### Consolidating the project mix engines: yes

Reasons it’s reasonable:

- There is substantial **logic duplication** between realtime and offline mixing:
  - lane graph creation
  - dynamics processor instantiation + parameter configuration
  - gain conversion helpers (`db`, fade floors)
  - crossfade planning + voice assignment strategy
  - fade curve implementation
- Drift risk is real: as features are added (more voices, automation, effects, partial renders), keeping the two implementations behaviorally identical will get harder.
- The consolidation boundary is clean: “plan” code can be pure and well-tested without needing audio hardware.

### Consolidating AIOEngine with project mixing: probably not (yet)

Reasons it’s likely not worth doing now:

- The responsibilities are very different (tap/capture resilience vs deterministic multi-clip scheduling).
- AIOEngine has a lot of defensive code for route changes, interruptions, and “session not ready” states that would become a shared failure surface for mixing.
- The main near-term duplication is not between AIOEngine and the mix engines; it’s between realtime and offline mixing.

That said, a *small* amount of shared infrastructure could still be worthwhile (see “Notable opportunities” below).

## Future Value of Consolidating the Project Mix Implementations

If the project direction includes any of the following, a shared “mix plan” pays off quickly:

- **Feature growth without semantic drift**
  - Any change to crossfades, gain staging, limiting, or scheduling semantics is made once.
- **Partial export / stem export**
  - A plan with explicit ranges makes it straightforward to render [t0, t1] or per-lane stems, using the same planner.
- **More sophisticated automation**
  - Clip/lane gain envelopes, fades of arbitrary shape, keyframes, ducking, etc. fit naturally into a plan representation.
- **Alternative backends**
  - The `Packages/AIO/Sources/AIO.docc/core-audio-layer-opportunities.md` document already points at a possible future Core Audio backend for capture. A pure “mix plan” also makes it easier to:
    - keep AVAudioEngine for mix playback while moving capture lower-level, or
    - eventually implement a Core Audio render path for export/mix determinism.
- **Testing**
  - Crossfade planning and scheduling can be unit-tested at the plan level (no audio hardware, no simulator flakiness).

## Implementation Quality (Reliability, Efficiency, Notable Risks)

### ProjectMixEngine (realtime)

Strengths:

- Clear graph topology and a good “2 voices per lane” model for crossfades.
- Precomputes scheduling (segments + fades + boundary gain events), which keeps runtime work small.
- Inserts a real limiter stage (Apple Dynamics Processor) to make “boost above 0 dB” predictable.
- Live lane/clip gain APIs update both:
  - the future event stream, and
  - any currently-active voice nodes.

Notable risks / limitations:

- Crossfades are implemented as **stepped parameter updates** on a 16ms timer. On short fades (120ms) this can be audibly “zippery” on some material; it’s correct semantically but not sample-accurate.
- `pause()` / `seek()` rebuild the entire graph and reschedule all clips. That’s robust, but it can be costly for large sessions and may cause audible gaps if used for scrubbing.
- Route changes and interruptions aren’t handled inside the engine; it assumes the broader `AudioEnvironmentManager` has established a working session.

### ProjectMixOfflineRenderer (offline)

Strengths:

- Uses manual rendering mode, which is the right approach for deterministic export on Apple platforms.
- Explicitly handles `.insufficientDataFromInputNode` as silence (useful when scheduling gaps exist).
- The concurrency story is clean: the renderer is an `actor` and the engine lives entirely inside a single `render(...)` call.

Notable risks / limitations:

- Hard-coded output format (48 kHz stereo) may cause quality differences vs realtime playback (depending on device route/sample-rate); this might be intended, but it’s a semantic decision worth making explicit.
- The render loop allocates a new `AVAudioPCMBuffer` each block; usually fine, but this is an obvious optimization point if export performance becomes a priority.
- It currently renders from time 0 to session end; adding range renders would require model changes (and further increases the motivation to consolidate via a shared plan).

### AIOEngine (recording + simple playback)

Strengths:

- Defensive, production-minded handling of common `AVAudioEngine` pitfalls:
  - validates formats before `installTap` to avoid uncatchable exceptions
  - route change handler attempts to keep recording alive by reinstalling taps
  - interruption handler stops cleanly and reports via callbacks
  - reconciliation loop for transient “session not ready” failures
- Proper separation between real-time work (tap callback) and file I/O (writer task).
- Converter caching reduces per-buffer overhead when format conversion is needed.

Notable risks / limitations:

- The writer loop uses `Task.yield()` when there are no frames; depending on scheduling, this can become a busy-ish loop. A short `Task.sleep` backoff (or an async signal from the tap path) would be more power-friendly.
- Per-channel ring buffer capacity is computed as `sampleRate * channelCount * 2` (per channel). For large channel counts this over-allocates by `channelCount`. It’s probably fine for typical 1–2ch inputs, but it’s a scaling footgun.
- Playback is connected directly to `outputNode` (no mixer/limiter). That’s simple, but it means:
  - no shared gain staging with project playback
  - no future-proof “master chain” for effects/limiting on simple playback

## Notable Opportunities (Low-Risk Refactors)

If the goal is to reduce future maintenance cost without destabilizing capture/playback:

1) Consolidate **project mixing duplication** first:
   - extract a shared “planner” module (session → plan)
   - extract a shared AVFoundation “graph builder” (nodes + limiter configuration)
2) Standardize gain helpers and limiter configuration in one place (they are currently duplicated).
3) Add plan-level tests for edge cases that currently only log warnings (e.g., “>2 voices needed” overlap cases).

If later you want deeper consolidation (single engine / Core Audio):

- Do it as a deliberate project: define a top-level “audio subsystem” state machine and migrate one mode at a time, keeping the “plan” as the stable contract between UI/editor semantics and the backend.

