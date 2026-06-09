// System-audio capture controls (macOS only).
//
// Demonstrates the public process-discovery API:
// - SystemAudioProcessCatalog.capturableProcesses() to list audio processes,
// - SystemAudioProcessSelection (.exclude / .includeOnly) by object id,
// driven by the AudioIODemoViewModel. "All system audio" is a global tap that
// excludes this app (so the demo never captures its own output); "Only the
// selected apps" is an include-only mixdown of the checked processes.

#if os(macOS)
  import AudioIO
  import SwiftUI

  struct SystemAudioControls: View {
    @Bindable var viewModel: AudioIODemoViewModel

    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Capture", selection: $viewModel.systemAudioMode) {
          ForEach(SystemAudioCaptureMode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .pickerStyle(.radioGroup)

        if viewModel.systemAudioMode == .selectedApps {
          HStack {
            Text("Capturable apps")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
            Spacer()
            Button("Refresh") { viewModel.refreshProcesses() }
              .controlSize(.small)
          }
          processList
        }
      }
      .disabled(viewModel.isRecording)
      .task { viewModel.refreshProcesses() }
    }

    @ViewBuilder private var processList: some View {
      if viewModel.availableProcesses.isEmpty {
        Text("No audio processes found yet. Play audio in another app, then Refresh.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(viewModel.availableProcesses) { process in
              Toggle(isOn: binding(for: process.id)) {
                VStack(alignment: .leading, spacing: 0) {
                  Text(process.name ?? process.bundleIdentifier ?? "pid \(process.processID)")
                  if let bundle = process.bundleIdentifier {
                    Text(bundle)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                }
              }
              .toggleStyle(.checkbox)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
        }
        .frame(maxHeight: 150)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
      }
    }

    private func binding(for id: SystemAudioProcessObjectID) -> Binding<Bool> {
      Binding(
        get: { viewModel.selectedProcessIDs.contains(id) },
        set: { isOn in
          if isOn {
            viewModel.selectedProcessIDs.insert(id)
          } else {
            viewModel.selectedProcessIDs.remove(id)
          }
        },
      )
    }
  }
#endif
