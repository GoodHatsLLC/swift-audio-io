# AIO

AIO is a Swift audio I/O package. Import `AIOEngine` for recording, file and segment
playback, audio-session configuration types, and live visualization.

## License

AIO is licensed under the GNU Affero General Public License, version 3 only
(`AGPL-3.0-only`). See `LICENSE`.

## Quickstart

```swift
import AIOEngine

@MainActor
func runAIOQuickstart() async throws {
  let engine = AIOEngine()

  let visualization = AudioVisualizationEngine(
    configuration: .init(sampleRate: 48_000)
  )
  let receiverToken = await engine.attachBufferReceiver(visualization)
  defer { receiverToken.invalidate() }

  let visualizationSubscription = visualization.subscribe(
    request: VisualizationRequest(
      work: VisualizationWork(
        lod: LODWork(
          configuration: MultiBandLODConfiguration(
            bandCount: 5,
            lodRatio: 128,
            bufferSeconds: 300,
            sampleRate: 48_000
          ),
          publishRateHz: 60
        ),
        analysis: AnalysisWork(
          updateRateHz: 30,
          timeDomain: .realTime
        )
      ),
      eventMask: [.lodSnapshot, .timeDomain]
    )
  ) { event in
    switch event {
    case .lodSnapshot:
      _ = visualization.withCurrentLODSnapshotRef { snapshot in
        snapshot.bandCount
      }
    case .timeDomain(let data):
      _ = data.rmsLevel
    default:
      break
    }
  }
  defer { visualizationSubscription.cancel() }
  visualization.startVisualization()

  let configuration = RecordingConfiguration(
    inputConfiguration: InputConfiguration(
      sampleRate: .common(.sr48000),
      channels: .stereo
    ),
    outputConfiguration: OutputConfiguration(
      fileFormat: .caf,
      bitDepth: .pcmFloat32,
      quality: .maximum
    )
  )

  try await engine.startRecording(configuration: configuration)
  let recordedFile = try await engine.stopRecording()

  _ = try await engine.play(url: recordedFile)
  await engine.stopPlayback()

  _ = try await engine.playSegment(
    url: recordedFile,
    startTime: 0,
    endTime: 1
  )
  _ = try engine.scrub(to: 0.25)
  await engine.stopPlayback()
}
```

This quickstart is mirrored by `AIOQuickstart.swift` in the AIO test target and is
type-checked by `xcrun swift test --package-path Packages/AIO`, which is also invoked by
`bin/test-aio-gate.sh`.

## Verification

```bash
xcrun swift test --package-path Packages/AIO
```

Use `bin/test-aio-gate.sh` before an AIO release when the real-platform harnesses are
available. That gate also runs the workspace-only `AIOPlatformIntegrationTests` scheme
for iOS Simulator audio-session, segment playback, channel-matrix, writer-drain, and
rotation coverage.

## Release Versioning

AIO follows Semantic Versioning for the public API exposed by the declared SwiftPM
library products: `AIOEngine`, `AudioSignals`, and `Tools`.

- Before `1.0.0`, minor releases may include source-breaking API changes, but every
  break must be called out in `CHANGELOG.md`.
- At and after `1.0.0`, source-breaking public API changes require a major-version
  bump.
- Patch releases are for compatible fixes only.
- `@_spi(TESTING)` and DEBUG-only helpers are not part of the semver-stable public API.

## Release CI Matrix

The release gate is split by the package's declared platforms. Locally, run the full
gate with `bin/test-aio-gate.sh`. In CircleCI, trigger the `aio-release-gate` workflow
with `run-aio-release-gate=true`.

| Declared platform | Required gate |
| --- | --- |
| macOS 26.2 | `xcrun swift build --package-path Packages/AIO`, `xcrun swift test --package-path Packages/AIO`, and `AIOHarnessMacUITests` on macOS |
| iOS 26.2 | `AIOPlatformIntegrationTests` and `AIOHarnessiOSUITests` on iOS Simulator |
