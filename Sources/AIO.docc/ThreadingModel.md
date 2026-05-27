# Threading Model

AudioIO uses five distinct thread domains. The public surface is `@MainActor`-isolated; cross-domain handoff goes through lock-free primitives.

## The five domains

The engine partitions work across these domains, illustrated for recording but the same shape applies to playback:

```
┌─────────────────────────────────────────────────────────────────┐
│                   MainActor (UI / State)                       │
│  isRecording, playback, reconciliation, callbacks,             │
│  AVAudioSession configuration, lifecycle coordination          │
└──────────────────┬──────────────────────┬──────────────────────┘
                   │                      │
          sync dispatch              async dispatch
                   │                      │
┌──────────────────▼──────────────────┐   │
│     engineControlQueue (serial)     │   │
│  attach, connect, start, stop,      │   │
│  prepare, reset, installTap         │   │
└──────────────────┬──────────────────┘   │
                   │                      │
            [AVAudioEngine                │
             manages internally]          │
                   │                      │
┌──────────────────▼──────────────────┐   │
│       Tap Thread (semi-RT)          │   │
│  processAudio() — convert, enqueue  │   │
│  to SPSC ring buffers               │   │
│  Lock-free reads via TapSnapshot    │   │
└────┬──────────────────────┬─────────┘   │
     │ SPSC                 │ SPSC        │
     ▼                      ▼             │
┌────────────┐    ┌──────────────────┐    │
│ writerQueue│    │  receiverQueue   │◄───┘
│ (file I/O) │    │ (visualization)  │
└────────────┘    └──────────────────┘
```

Cross-domain synchronization uses only:
- MainActor ↔ engineControlQueue: sync/async dispatch.
- engineControlQueue ↔ tap thread: snapshot-based atomic reads.
- tap thread ↔ writer / receiver queues: SPSC ring buffers, atomic counters.

## What's `@MainActor`

The following are MainActor-isolated and must be called from the main actor (or with `await`):

- ``AIOEngine/startRecording(configuration:)``, ``AIOEngine/stopRecording()``, ``AIOEngine/rotateRecordingFile()``.
- ``AIOEngine/play(url:)``, ``AIOEngine/playSegment(url:startTime:endTime:playbackPollingInterval:)``, ``AIOEngine/stopPlayback()``, ``AIOEngine/scrub(to:updatePlaybackPolling:)``.
- ``AIOEngine/isRecording``, ``AIOEngine/playback``, and the other observable state.
- The closure passed to ``AudioVisualizationEngine/subscribe(request:handler:)``.

## What's `nonisolated`

The following can be called from any context (including the realtime tap callback):

- ``AIOEngine/events`` (the broadcaster itself is `Sendable`; the subscription iteration runs in the consumer's context).
- ``AudioVisualizationEngine/currentTimeSeconds`` and ``AudioVisualizationEngine/currentSampleRate``.
- ``AudioVisualizationEngine/withCurrentLODSnapshotRef(_:)`` — frame-scoped zero-copy LOD reads from any thread.
- ``BufferReceiver/processBuffer(_:)`` and ``BufferReceiver/processBuffer(_:timing:)`` — the realtime tap calls these on the tap thread.

## Subscriber tasks and broadcaster delivery

``AIOEngine/events`` is an `AsyncBroadcaster<AudioIOEvent>`. Each subscriber's iteration runs in its own task; the broadcaster's upstream fan-out task delivers events asynchronously. Concretely:

- A `Subject.send(_:)` call is synchronous and lock-free, but **does not** synchronously deliver to subscribers.
- Subscribers receive events through a per-subscriber unbounded buffer in send order (FIFO).
- New subscribers do not get replay of past events. Subscribe before driving the engine if you need the first event.

When testing event-stream behavior, poll for the expected state with a `waitUntil(...)` helper rather than asserting on subscriber state immediately after the producer's `await` returns — the producer is decoupled from broadcaster delivery.

## Realtime callback hygiene

The tap thread runs `processBuffer(_:)` at audio-rate cadence (~5ms for typical configurations). Code on this path must:

- Avoid allocation.
- Avoid blocking primitives (locks, semaphores, dispatch sync).
- Use the provided SPSC ring buffers and atomics for cross-thread state.

The library's built-in receivers (``AudioVisualizationEngine``, the file-write tap) follow this discipline. Custom ``BufferReceiver`` implementations must do the same.
