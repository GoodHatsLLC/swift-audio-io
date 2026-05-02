# Multi-Band LOD Contract

This document defines the runtime contract between the CPU multi-band LOD pipeline
(`MultiBandLODProcessor`) and any consumer-owned renderer.

## Definitions

- `rawBufferLength`: Total raw sample capacity of the circular history buffer, in samples.
- `lodRatio`: Number of raw samples aggregated into a single LOD sample.
- `lodLength`: Number of LOD samples per band.
  - Canonical: `lodLength == lodBufferLength == ceil(rawBufferLength / lodRatio)`
- `writeIndex`: The **next** LOD index that will be written (0..<`lodLength`).
  - The most recent committed sample is at `writeIndex - 1` (wrapped by `lodLength`).

## Buffer Layout (CPU → GPU)

Each of the three LOD channels (`min`, `max`, `rms`) is uploaded to the GPU as a single flat float buffer:

```
[ band0 (lodLength floats) ][ band1 (lodLength floats) ] ... [ bandN-1 (lodLength floats) ]
```

This is **band-contiguous**, not interleaved.

## Indexing and Wrapping

Renderers typically interpret screen-space X as “samples ago from the most recent commit”.

When converting any index to an array read:

- All indices MUST be wrapped modulo `lodLength` using a correct modulo for negative values.
- No renderer may assume `rawBufferLength` is an integer multiple of `lodRatio`.

## Zoom + Offset Semantics

- `zoom` is a multiplicative zoom factor in the time axis:
  - Current (contract v1): `zoom = 1` shows **half** of the history; visible LOD samples are `lodLength / (zoom * 2)`.
  - Increasing `zoom` shows a smaller, more detailed window.
- `viewOffset` is “how many raw samples ago from ‘now’ the right edge should be”, expressed in raw samples:
  - `viewOffset = 0` means the right edge aligns to the most recent commit.
  - Increasing `viewOffset` pans left (older audio).

## Live vs Offline Invariants

- Offline renders must represent the full audio file (subject to any explicit output-width caps).
- Live renders must avoid per-frame allocations/copies on the UI path.
