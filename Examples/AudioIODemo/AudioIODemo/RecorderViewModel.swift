// The single state holder for the sample. Owns the AIOEngine, the
// AudioVisualizationEngine, and the events-stream subscriber task.
//
// Reading order if you're learning the library from this file:
//
// 1. init() — subscribes to engine.events BEFORE the caller can drive the
//    engine. This is load-bearing: AsyncBroadcaster does not replay events
//    for late subscribers, so the subscriber must be set up first.
// 2. attachVisualization() — token-scoped buffer-receiver attachment plus
//    a visualization subscription that requests LOD work. The handler
//    sink is a no-op because the View reads the LOD snapshot directly
//    via withCurrentLODSnapshotRef on a TimelineView tick.
// 3. toggleRecording() — canonical typed-throws start/stop with
//    AIOEngine.startRecording(configuration:) and stopRecording().
// 4. play() — replay the last recording via AIOEngine.play(url:).

import AudioIO
import Foundation
import Observation

@Observable
@MainActor
final class RecorderViewModel {
  let engine = AIOEngine()
  let visualization = AudioVisualizationEngine(configuration: .realTimeRecording)

  private(set) var isRecording = false
  private(set) var isPlaying = false
  private(set) var lastRecordingURL: URL?
  private(set) var statusLine = "Idle"
  private(set) var lastError: String?

  private var eventTask: Task<Void, Never>?
  private var receiverToken: BufferReceiverToken?
  private var subscription: VisualizationSubscription?

  init() {
    eventTask = Task { @MainActor [weak self] in
      guard let self else { return }
      for await event in self.engine.events {
        self.handle(event)
      }
    }
  }

  @MainActor
  deinit {
    eventTask?.cancel()
    receiverToken?.invalidate()
    subscription?.cancel()
  }

  func attachVisualization() async {
    let token = await engine.attachBufferReceiver(visualization)
    receiverToken = token
    subscription = visualization.subscribe(
      request: VisualizationRequest(
        work: VisualizationWork(
          lod: LODWork(configuration: .default, publishRateHz: 60),
        ),
        eventMask: [.lodSnapshot],
      ),
    ) { _ in
      // No-op: WaveformView pulls the snapshot directly via
      // withCurrentLODSnapshotRef on each TimelineView tick.
    }
    visualization.startVisualization()
  }

  func toggleRecording() async {
    if isRecording {
      do {
        _ = try await engine.stopRecording()
      } catch {
        lastError = error.localizedDescription
        statusLine = "Stop failed"
      }
      return
    }

    let configuration = RecordingConfiguration(
      inputConfiguration: InputConfiguration(
        sampleRate: .cd,
        channels: .mono,
      ),
      outputConfiguration: OutputConfiguration(
        fileFormat: .caf,
        bitDepth: .pcmFloat32,
        quality: .maximum,
      ),
    )
    do {
      _ = try await engine.startRecording(configuration: configuration)
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusLine = "Start failed"
    }
  }

  func play() async {
    guard let url = lastRecordingURL else { return }
    do {
      _ = try await engine.play(url: url)
    } catch {
      lastError = error.localizedDescription
      statusLine = "Play failed"
    }
  }

  func stopPlayback() async {
    await engine.stopPlayback()
  }

  private func handle(_ event: AudioIOEvent) {
    switch event {
    case .recordingStarted(let url, let format):
      isRecording = true
      lastRecordingURL = url
      statusLine = "Recording → \(url.lastPathComponent) (\(format))"
    case .recordingCompleted:
      isRecording = false
      statusLine = "Saved \(lastRecordingURL?.lastPathComponent ?? "")"
    case .recordingFailed:
      isRecording = false
      statusLine = "Recording failed"
    case .recordingInterruption(let interruption):
      statusLine = "Interruption: \(interruption.description)"
    case .playbackStateChanged(let playback):
      isPlaying = playback?.isPlaying == true
      statusLine = isPlaying ? "Playing \(playback?.file.lastPathComponent ?? "")" : "Stopped"
    case .playbackUpdated:
      // Tick-rate updates. WaveformView already redraws on its own clock.
      break
    case .error(let error):
      lastError = error.localizedDescription
      statusLine = "Engine error"
    case .reconciliationFailed:
      // Only fires on the @_spi(Advanced) reconciliation entry points,
      // which this sample doesn't use.
      break
    }
  }
}
