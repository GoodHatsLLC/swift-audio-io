# Core Audio Layer Opportunities

This survey highlights functionality the current AIOEngine (built on `AVAudioEngine` and
`AVAudioFile`) does **not** implement but could be unlocked by dropping down to the Core
Audio I/O units used by the iOS recording stack.

## Current RT-safety model (AVAudioEngine)
- The tap callback only converts and enqueues into lock-free SPSC buffers (no receiver calls).
- Buffer receivers run on a dedicated `receiverQueue`, reading from a separate ring buffer.
- Converter and converted buffers are prebuilt during warm/route change to keep the tap allocation-free.

## Voice-processing controls
- The engine configures the shared `AVAudioSession` with the `.playAndRecord` category and
  default options but never instantiates or configures the Voice Processing I/O unit
  (`kAudioUnitSubType_VoiceProcessingIO`). This means built-in acoustic echo cancellation,
  automatic gain control, and noise suppression cannot be tuned or toggled per stream.
- Using Core Audio directly would allow attaching the voice-processing Audio Unit, exposing
  runtime controls (AEC enable/bypass, AGC target levels) and measurements (residual echo,
  noise floor) that are unavailable through the current `AVAudioEngine` abstraction.

## Multi-route and multi-mic capture
- Recording attaches a single tap to the `inputNode` on bus `0` and requests one preferred
  input channel count, so only one active hardware route is captured at a time.
- Dropping to Core Audio would make it possible to enable multi-route capture (e.g., built-in
  mic + USB mic simultaneously), record each hardware stream into its own buffer, and apply
  per-route latency compensation—capabilities `AVAudioEngine` cannot expose when restricted
  to one input bus.

## Sample-accurate capture/monitor pipelines
- The pipeline relies on `AVAudioEngine` callbacks and `AVAudioFile` for format conversion
  and writing, which hides the render callbacks and hardware timestamps needed for
  deterministic latency, tight drift correction, or phase-aligned live monitoring.
- Building on the Core Audio render callback APIs would allow scheduling using host time
  stamps, implementing custom buffer sizing, or injecting bespoke Audio Units for
  phase-aligned monitoring paths (e.g., zero-latency foldback) that the current high-level
  engine cannot surface.

## Architecture changes required for a Core Audio stack
- **Session bootstrap:** Configure `AVAudioSession` explicitly for voice processing or
  multi-route capture (e.g., `setCategory(.playAndRecord, options: [.allowBluetoothA2DP,
  .allowAirPlay, .allowBluetooth])`), then create and activate the I/O audio unit with
  `kAudioUnitSubType_VoiceProcessingIO` to unlock AEC/AGC controls.
- **I/O graph definition:** Replace `AVAudioEngine` nodes with an `AUGraph` (or manual
  `AudioComponentInstance` wiring) that connects the voice-processing I/O unit to a custom
  mixer for monitoring and to separate format converters for each recording target.
- **Render callbacks:** Register input and output callbacks to pull buffers directly from
  hardware using host time stamps. This allows implementing drift correction and
  zero-latency foldback without the buffering `AVAudioEngine` introduces.
- **Per-route capture:** Enable multi-route on the session, create distinct input elements
  per hardware route, and write each to its own `ExtAudioFile` or ring buffer so USB and
  built-in mics remain isolated with independent latency compensation.
- **Format management:** Perform sample-rate conversion and channel mapping using Audio
  Converter or dedicated Audio Units, keeping a shared `AudioStreamBasicDescription` for
  each path instead of relying on `AVAudioFile`’s implicit conversions.
- **Threading and safety:** Run render callbacks on real-time threads only, deferring file I/O
  and analytics to worker queues through lock-free ring buffers to preserve determinism.
- **Monitoring path:** Feed captured buffers into a low-latency monitor mixer, optionally
  bypassing voice processing for artist foldback while leaving processing enabled for the
  recorded path.
