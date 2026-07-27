# AudioIO

AudioIO describes recording and playback in terms of the audio capabilities a caller can rely on, rather than partially applied platform configuration.

## Language

**Audio environment**:
The selectable microphone inputs and sources, requested configuration,
applied platform state, and capabilities that govern capture. It is the sole
authority for user microphone configuration; a recording consumes a settled
value without taking ownership of those preferences.
_Avoid_: Session manager, device state

**Requested input configuration**:
Durable user intent for input device, source and polar pattern, channel count,
sample rate, and processing mode. A request remains meaningful while the audio
environment is inactive or its device is temporarily absent.
_Avoid_: Selected input, configured channels

**Applied input configuration**:
The input, source, format, and processing mode read back from the active
platform route after a reconciliation attempt. It is absent while inactive and
never overwrites the request when the platform rejects or defers it.
_Avoid_: Current preference, effective request

**Input reconciliation**:
The serialized resolution, platform application, and readback operation that
classifies the latest request as discovering, deferred, reconciling, satisfied,
or unsatisfied. Automatic policy belongs here; exact requests never fall back.
_Avoid_: Apply stereo, restore preferences

**Settled microphone configuration**:
The immutable format, optional explicit input, source identity, and request
generation admitted through reconciliation for one capture start.
_Avoid_: Environment snapshot, current channels

**Audio-session authority**:
The owner that decides when the shared platform audio session is active and which recording processing mode it uses. An engine either owns that decision itself or is composed with one authority for its lifetime.
_Avoid_: Audio session delegate, activation callback

**Microphone recording readiness**:
The state in which the latest requested input configuration has reconciled,
readback is satisfied, and both the active route and capture format can supply
the requested channel count. A temporary mismatch is not readiness, even when
the hardware is generally capable of the request.
_Avoid_: Session readiness, input configured

**Recording intent**:
A caller's decision that capture should be active or inactive. Recording intent belongs to the caller and can differ from actual recording state while an awaited start or stop is in progress.
_Avoid_: Engine desire, wantsRecording

**Capture backend**:
The internal adapter that owns how one prepared recording source starts producing samples, stops gracefully or immediately, and releases source resources. Microphone and system-audio capture both use this seam; the absence of an adapter means no source is staged.
_Avoid_: Non-microphone backend, backend-present source detection

**Recording lifecycle**:
The ordered transition from recording intent through readiness, active capture, file rotation, and either graceful or immediate stop. It is the sole owner of recording state even though callers observe and control it through the engine.
_Avoid_: Recording runtime, engine recording internals

**Audio system event**:
A captured, platform-neutral fact about a route transition, interruption, or media-services lifecycle change. It contains the values needed for deterministic recovery without retaining or rereading a live platform session.
_Avoid_: AVAudioSession notification, platform event callback

**Audio recovery**:
The decision to continue, stop, defer, or restart recording or playback after an audio system event. Recovery owns pending restart state; recording and playback lifecycles own the operations it invokes.
_Avoid_: Interruption handler, platform recovery
