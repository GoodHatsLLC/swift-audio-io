// The single state holder for the sample. Owns the AIOEngine, the
// AudioVisualizationEngine, and the events-stream subscriber task.
//
// Reading order if you're learning the library from this file:
//
// 1. init() — subscribes to engine.events BEFORE the caller can drive the
//    engine. This is load-bearing: AsyncBroadcaster does not replay events
//    for late subscribers, so the subscriber must be set up first.
// 2. attachVisualization() — token-scoped buffer-receiver attachment plus
//    a visualization subscription that requests LOD work. The same receiver
//    pipeline feeds the waveform for both microphone and system-audio capture.
// 3. toggleRecording() — canonical typed-throws start/stop with
//    AIOEngine.startRecording(configuration:) and stopRecording(). The
//    RecordingConfiguration is built from the selected source.
// 4. play() — replay the last recording via AIOEngine.play(url:).
//
// macOS system-audio capture (Core Audio process tap) is selectable via
// `selectedSource`. It uses the public process-discovery API
// (SystemAudioProcessCatalog) and requires NSAudioCaptureUsageDescription
// (see project.yml); the macOS audio-recording permission prompt appears on the
// first capture, separately from the microphone permission.

import AudioIO
import Foundation
import Observation

#if os(macOS)
  import AppKit
#endif

/// Which capture source the demo records from.
enum RecordingSource: String, CaseIterable, Identifiable, Sendable {
  case microphone
  #if os(macOS)
    case systemAudio
  #endif

  var id: String { rawValue }

  var label: String {
    switch self {
    case .microphone: "Microphone"
    #if os(macOS)
      case .systemAudio: "System Audio"
    #endif
    }
  }
}

#if os(macOS)
  /// How a system-audio recording selects processes.
  enum SystemAudioCaptureMode: String, CaseIterable, Identifiable, Sendable {
    case excludeThisApp
    case selectedApps

    var id: String { rawValue }

    var label: String {
      switch self {
      case .excludeThisApp: "All system audio (exclude this app)"
      case .selectedApps: "Only the selected apps"
      }
    }
  }
#endif

@Observable
@MainActor
final class RecorderViewModel {
  let engine = AIOEngine()
  let visualization = AudioVisualizationEngine(configuration: .realTimeRecording)

  var selectedSource: RecordingSource = .microphone

  #if os(macOS)
    var systemAudioMode: SystemAudioCaptureMode = .excludeThisApp
    private(set) var availableProcesses: [SystemAudioProcess] = []
    var selectedProcessIDs: Set<SystemAudioProcessObjectID> = []
  #endif

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

  /// Attach the visualization receiver. Safe to call regardless of microphone
  /// permission — the same receiver pipeline feeds the waveform for system audio.
  func attachVisualization() async {
    guard receiverToken == nil else { return }
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

  /// Whether the Record button should be enabled for the current source.
  /// Microphone needs its permission granted; system audio prompts for the
  /// macOS audio-recording permission lazily on first capture.
  func canRecord(microphonePermissionGranted: Bool) -> Bool {
    switch selectedSource {
    case .microphone: microphonePermissionGranted
    #if os(macOS)
      case .systemAudio: true
    #endif
    }
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

    let configuration: RecordingConfiguration
    switch selectedSource {
    case .microphone:
      configuration = RecordingConfiguration(
        inputConfiguration: InputConfiguration(sampleRate: .cd, channels: .mono),
        outputConfiguration: OutputConfiguration(
          fileFormat: .caf,
          bitDepth: .pcmFloat32,
          quality: .maximum,
        ),
      )
    #if os(macOS)
      case .systemAudio:
        configuration = makeSystemAudioConfiguration()
    #endif
    }

    do {
      _ = try await engine.startRecording(configuration: configuration)
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusLine = "Start failed"
    }
  }

  #if os(macOS)
    /// Refresh the list of processes the HAL currently exposes as audio sources.
    func refreshProcesses() {
      do {
        let processes = try SystemAudioProcessCatalog.capturableProcesses()
        availableProcesses =
          processes
          .filter { $0.name != nil || $0.bundleIdentifier != nil }
          .sorted {
            let lhs = $0.name ?? $0.bundleIdentifier ?? ""
            let rhs = $1.name ?? $1.bundleIdentifier ?? ""
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
          }
        // Drop selections that are no longer present.
        let present = Set(availableProcesses.map(\.id))
        selectedProcessIDs.formIntersection(present)
      } catch {
        lastError = "Process list failed: \(error.localizedDescription)"
      }
    }

    /// Reveal the last recording in Finder, for quick manual verification.
    func revealLastRecording() {
      guard let url = lastRecordingURL else { return }
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func makeSystemAudioConfiguration() -> RecordingConfiguration {
      let selection: SystemAudioProcessSelection
      switch systemAudioMode {
      case .excludeThisApp:
        selection = SystemAudioProcessSelection(mode: .exclude)
      case .selectedApps:
        selection = SystemAudioProcessSelection(
          mode: .includeOnly,
          processObjectIDs: Array(selectedProcessIDs),
        )
      }
      let input = SystemAudioRecordingInput(
        // System audio is mixed to stereo; 48 kHz matches the typical system mix.
        format: InputConfiguration(sampleRate: .dvd, channels: .stereo),
        processSelection: selection,
        excludesCurrentProcess: true,
      )
      return RecordingConfiguration(
        input: .systemAudio(input),
        outputConfiguration: OutputConfiguration(
          fileFormat: .caf,
          bitDepth: .pcmFloat32,
          quality: .maximum,
        ),
      )
    }
  #endif

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
      statusLine = "Recording \(selectedSource.label) → \(url.lastPathComponent) (\(format))"
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
      // Only fires on the reconciliation-mode entry points, which this sample
      // doesn't use.
      break
    }
  }
}
