// The whole UI of the sample, in one place.
//
// Layout: a source picker (microphone, or — on macOS — system audio), the
// source-specific controls, a waveform that renders the live multi-band LOD
// during recording, record/play controls, and a status line wired to the
// AIOEngine.events stream.
//
// The waveform works for both sources: the visualization buffer-receiver is
// attached to the engine up front and is fed by the same pipeline regardless of
// whether samples come from the microphone tap or the system-audio backend.

import AudioIO
import SwiftUI

struct ContentView: View {
  @State private var viewModel = AudioIODemoViewModel()
  @State private var permission: MicrophonePermission = .unknown

  var body: some View {
    @Bindable var viewModel = viewModel

    VStack(spacing: 18) {
      header

      #if os(macOS)
        Picker("Source", selection: $viewModel.selectedSource) {
          ForEach(RecordingSource.allCases) { source in
            Text(source.label).tag(source)
          }
        }
        .pickerStyle(.segmented)
        .disabled(viewModel.isRecording)

        if viewModel.selectedSource == .systemAudio {
          SystemAudioControls(viewModel: viewModel)
        }
      #endif

      WaveformView(visualization: viewModel.visualization)
        .frame(height: 140)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

      controls

      statusLine

      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(minWidth: 420, minHeight: 560)
    .task {
      // The visualization receiver feeds the waveform for both sources, so attach
      // it regardless of microphone permission.
      await viewModel.attachVisualization()
      permission = MicrophonePermission.current()
      if permission == .unknown {
        permission = .requesting
        permission = await MicrophonePermission.request()
      }
    }
  }

  private var microphoneGranted: Bool { permission == .granted }

  @ViewBuilder private var header: some View {
    HStack {
      Text("AudioIO Demo")
        .font(.title2.bold())
      Spacer()
      Image(systemName: microphoneGranted ? "mic.fill" : "mic.slash")
        .foregroundStyle(microphoneGranted ? Color.secondary : Color.red)
    }
  }

  @ViewBuilder private var controls: some View {
    HStack(spacing: 12) {
      Button {
        Task { await viewModel.toggleRecording() }
      } label: {
        Label(
          viewModel.isRecording ? "Stop" : "Record",
          systemImage: viewModel.isRecording ? "stop.circle.fill" : "record.circle.fill",
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(viewModel.isRecording ? .red : .accentColor)
      .disabled(!viewModel.canRecord(microphonePermissionGranted: microphoneGranted))

      Button {
        Task {
          if viewModel.isPlaying {
            await viewModel.stopPlayback()
          } else {
            await viewModel.play()
          }
        }
      } label: {
        Label(
          viewModel.isPlaying ? "Pause" : "Play",
          systemImage: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill",
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .disabled(viewModel.lastRecordingURL == nil || viewModel.isRecording)

      #if os(macOS)
        Button {
          viewModel.revealLastRecording()
        } label: {
          Label("Show", systemImage: "folder")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.lastRecordingURL == nil)
      #endif
    }
  }

  @ViewBuilder private var statusLine: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(viewModel.statusLine)
        .font(.footnote.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let error = viewModel.lastError {
        Text(error)
          .font(.caption.monospaced())
          .foregroundStyle(.red)
          .lineLimit(3)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

#Preview {
  ContentView()
}
