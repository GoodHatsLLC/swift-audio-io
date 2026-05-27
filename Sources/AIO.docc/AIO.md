# ``AIO``

@Metadata {
  @TechnologyRoot
}

AIO is a Swift audio I/O package for recording, playback, audio-session coordination,
and real-time audio visualization.

Import ``AudioIO`` for the primary public surface. The umbrella product re-exports
the recording, playback, session, visualization, and signal-processing types needed
to build a recorder or audio-analysis workflow without importing implementation
targets directly.

## Topics

### Start Here

- <doc:SPEC_AIO>
- <doc:SPEC_AUDIO_VIZ>
- <doc:MultiBandVisualization>

### Package Reference

- <doc:Architecture>
- <doc:Features>
- <doc:Development>

### Runtime Contracts

- <doc:MultiBandLODContract>
- <doc:core-audio-layer-opportunities>
