// © GoodHatsLLC

import AudioIO

@MainActor
func aioQuickstart() async throws {
  let engine = AIOEngine()

  let visualization = AudioVisualizationEngine(
    configuration: .init(sampleRate: 48_000),
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
            sampleRate: 48_000,
          ),
          publishRateHz: 60,
        ),
        analysis: AnalysisWork(
          updateRateHz: 30,
          timeDomain: .realTime,
        ),
      ),
      eventMask: [.lodSnapshot, .timeDomain],
    ),
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
      channels: .stereo,
    ),
    outputConfiguration: OutputConfiguration(
      fileFormat: .caf,
      bitDepth: .pcmFloat32,
      quality: .maximum,
    ),
  )

  try await engine.startRecording(configuration: configuration)
  let recordedFile = try await engine.stopRecording()

  _ = try await engine.play(url: recordedFile)
  await engine.stopPlayback()

  _ = try await engine.playSegment(
    url: recordedFile,
    startTime: 0,
    endTime: 1,
  )
  _ = try engine.scrub(to: 0.25)
  await engine.stopPlayback()
}
