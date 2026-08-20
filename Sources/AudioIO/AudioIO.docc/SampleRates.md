# Sample Rates

Why a sample rate is an intent on Apple platforms, and how AudioIO resolves it.

## The platform contract

On iOS an app cannot set the hardware sample rate. `setPreferredSampleRate` is
a hint the active route is free to ignore — there is no error when it does —
and `AVAudioSession.sampleRate` is the only readback of what the route
actually runs. Modern routes mostly ignore the hint:

| Route | Actual rate |
|---|---|
| Built-in mic (iPhone 6s and later) | 48 kHz, effectively pinned |
| Wired headset / USB interface | typically 44.1 or 48 kHz |
| Bluetooth HFP headset | 8–16 kHz |
| AirPods as microphone | 24 kHz |
| AirPods (H2) with high-quality recording (iOS 26) | 48 kHz |

macOS microphones and system-audio taps have real per-device rates, read from
the input node or the process tap's stream format.

## Sample rate as intent

``RecordingSampleRate`` makes the reality expressible instead of implicit:

- ``RecordingSampleRate/hardware`` — adopt whatever rate the route is running
  when capture starts. Zero-resample: the pipeline and file inherit the
  hardware rate. The recommended default for general capture.
- ``RecordingSampleRate/exact(_:)`` — deliver exactly this rate. AudioIO taps
  the hardware at its own format and converts, so the file always carries the
  requested rate no matter what the route does. The right choice when a
  downstream consumer dictates the rate — ``SampleRate/speech`` (16 kHz) for
  speech-to-text pipelines, for instance.

A ``CaptureFormat`` (intent + ``ChannelCount``) is what recording inputs
carry; ``InputConfiguration`` remains the resolved, exact shape.

### Resolution

A `.hardware` request resolves once per bring-up, after the audio session is
configured and active: the microphone path reads the input node's live format,
the macOS system-audio path reads the process tap's stream format. The
resolved rate is pinned for the life of the recording — a route change
mid-recording never changes the file's rate; the tap reinstalls at the new
hardware format and a converter bridges into the pinned rate, exactly as it
does for an exact request.

If the output encoder cannot write the observed rate (the AAC family tops out
at 48 kHz), the nearest encodable rate is used instead. The substitution — and
every other fact about how the request was satisfied — is visible in the
recording's provenance.

Interruptions re-resolve: a `.hardware` recording restarted after a phone call
adopts whatever route exists at restart, not the one from before it.

A `.hardware` request also writes **no** `setPreferredSampleRate` at all:
there is nothing to prefer, and skipping the write avoids a needless
route-change notification. The same is true of
``AudioSampleRatePreference/automatic`` in the declarative input-configuration
system — it never reports
``AudioInputConfigurationIssue/rejectedSampleRate(requested:applied:)``,
because it makes no request the platform could reject.

## Provenance: what was actually captured

The container rate says nothing about captured bandwidth: a 48 kHz file fed by
an 8 kHz Bluetooth HFP microphone dutifully upsamples, and the file *says*
48 kHz while carrying ~4 kHz of real audio. ``ResolvedCaptureFormat`` is the
honest record:

- ``ResolvedCaptureFormat/hardware`` — the format the route was running when
  the tap was installed.
- ``ResolvedCaptureFormat/processing`` — the format the pipeline converts to
  and the file is written at.
- ``ResolvedCaptureFormat/isResampling`` — whether a converter sits between
  them.
- ``ResolvedCaptureFormat/effectiveSampleRate`` — the lesser of the two rates:
  the ceiling on captured bandwidth. Drive quality badges off this, never the
  file's rate.

It reaches you three ways: on every
``AudioIOEvent/recordingStarted(url:format:capture:)`` event (initial start
and each rotation), as the observable ``AIOEngine/activeCaptureFormat``
(updated on route-change reinstalls, `nil` when not recording), and — for
mid-recording changes — alongside the
``AIOEngine/RecordingInterruption/routeChangeContinuing(event:qualityChange:)``
event's quality change.

## The Bluetooth microphone decision

Session category options choose your sample rate: allowing the Bluetooth
hands-free mic collapses the whole session to the HFP codec rate the moment a
headset is routed, while the high-quality A2DP output path has no microphone
at all. ``BluetoothMicrophonePolicy`` makes that trade explicit:

- ``BluetoothMicrophonePolicy/handsFree`` — Bluetooth mics work at 8–24 kHz.
  The default.
- ``BluetoothMicrophonePolicy/never`` — input stays on the built-in or wired
  mic at the full hardware rate; output stays on A2DP.
- ``BluetoothMicrophonePolicy/highQualityWhenAvailable`` — iOS 26's
  high-quality Bluetooth recording (48 kHz on H2-class AirPods) with HFP
  fallback. Adds input latency; unavailable in some regions, where the
  provenance shows the HFP rate that was actually delivered.

Pass it to `AudioSessionConfiguration.recordingConfiguration(useMeasurement:bluetoothMicrophone:)`
or set `AudioEnvironmentManager.recordingBluetoothMicrophonePolicy`.

## Choosing a rate

- **General capture / music**: ``RecordingSampleRate/hardware``. No conversion
  cost, no quality loss, and the file reflects what the microphone delivered.
- **Speech pipelines**: `.exact(.speech)` — 16 kHz mono is the industry STT
  target; the realtime downsample is what speech frameworks do themselves.
- **A delivery spec that demands 44.1 kHz**: `.exact(.cd)` and accept the
  always-on resample on modern hardware — or record at `.hardware` and
  resample offline with a mastering-grade converter, which the completion's
  provenance lets you decide after the fact.

## Topics

### Intent and resolution

- ``RecordingSampleRate``
- ``CaptureFormat``
- ``InputConfiguration``
- ``SampleRate``
- ``SampleRate/speech``

### Provenance

- ``ResolvedCaptureFormat``
- ``AIOEngine/activeCaptureFormat``
- ``AudioIOEvent/recordingStarted(url:format:capture:)``

### Session-level preferences

- ``AudioSampleRatePreference``
- ``BluetoothMicrophonePolicy``
- ``AudioInputConfigurationCapabilities/activeSampleRate``
- ``AudioInputConfigurationCapabilities/likelySampleRates``
