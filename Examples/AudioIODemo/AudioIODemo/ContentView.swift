// The whole UI of the sample, in one place.
//
// Layout: permission state at the top, a big record button, a waveform that
// renders the live multi-band LOD during recording, a status line wired to
// the AIOEngine.events stream, and a play button for the last recording.

import AudioIO
import SwiftUI

struct ContentView: View {
  @State private var viewModel = RecorderViewModel()
  @State private var permission: MicrophonePermission = .unknown

  var body: some View {
    VStack(spacing: 24) {
      header

      WaveformView(visualization: viewModel.visualization)
        .frame(height: 160)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

      controls

      statusLine

      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(minWidth: 360, minHeight: 480)
    .task {
      permission = MicrophonePermission.current()
      if permission == .unknown {
        permission = .requesting
        permission = await MicrophonePermission.request()
      }
      if permission == .granted {
        await viewModel.attachVisualization()
      }
    }
  }

  @ViewBuilder private var header: some View {
    HStack {
      Text("AudioIO Demo")
        .font(.title2.bold())
      Spacer()
      Image(systemName: permission == .granted ? "mic.fill" : "mic.slash")
        .foregroundStyle(permission == .granted ? Color.secondary : Color.red)
    }
  }

  @ViewBuilder private var controls: some View {
    HStack(spacing: 16) {
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
      .disabled(permission != .granted)

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
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

#Preview {
  ContentView()
}
