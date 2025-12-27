//
//fileprivate struct LogExportScreen: View {
//  fileprivate init(model: LogModel) {
//    self.model = model
//  }
//  @Bindable private var model: LogModel
//  @State private var showFileExporter: Bool = false
//  @State private var logFileDocument: MultiTypeFileDocument?
//  @State private var logFileDocumentType: UTType = .log
//  @State private var selectedExport: UTType = .log
//  @State private var showAlert: Bool = false
//  @State private var alertMessage: String = ""
//  @State private var showToast: Bool = false
//  
//  enum Destination {
//    case logList
//  }
//  @State var destination: Destination?
//  
//  var body: some View {
//    Form {
//      actionButtonsSection
//      filterOptions
//      
//      Section {
//        Button {
//          destination = .logList
//        } label: {
//          HStack {
//            Label("View logs", systemImage: "list.bullet.rectangle.fill")
//              .symbolRenderingMode(.hierarchical)
//            Spacer()
//            if model.isExporting {
//              ProgressView()
//                .controlSize(.small)
//            } else {
//              Image(systemName: "chevron.right")
//                .font(.caption)
//                .foregroundStyle(.secondary)
//            }
//          }
//        }
//        .buttonStyle(.borderless)
//        .disabled(model.isExporting)
//      } header: {
//        Label("Viewing", systemImage: "eye.fill")
//      } footer: {
//        if model.isExporting {
//          HStack(spacing: 8) {
//            ProgressView()
//              .controlSize(.small)
//            Text("Loading log entries...")
//              .font(.caption)
//              .foregroundStyle(.secondary)
//          }
//          .transition(.opacity.combined(with: .move(edge: .top)))
//        }
//      }
//    }
//    .formStyle(.grouped)
//    .navigationTitle("Export Logs")
//    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.isExporting)
//    .toolbar { toolbarComponents }
//    .task {
//      do {
//        try await model.subscribe()
//      } catch is CancellationError {
//        return
//      } catch {
//        model.error = error
//      }
//    }
//    .fileExporter(
//      isPresented: $showFileExporter,
//      document: logFileDocument,
//      contentType: selectedExport
//    ) { result in
//      handleFileExportResult(result)
//    }
//    .alert(
//      "Error",
//      isPresented: $showAlert
//    ) {
//      Button("OK", role: .cancel) {}
//    } message: {
//      Text(alertMessage)
//    }
//  }
//}
//
//extension LogExportScreen {
//  private func copyToClipboard() {
//    let logs = model.logs
//    Task { [logs] in
//      let logs = SystemLog.LogModel.exportLogs(logs, as: .plainText)
//      let contentToPaste = logs.isEmpty ? "Nothing to paste" : logs
//      setToPasteBoard(contentToPaste)
//      showToast = true
//    }
//  }
//
//  private func exportLogFile(type: UTType) {
//    guard logFileDocument == nil else {
//      showFileExporter.toggle()
//      return
//    }
//    Task {
//      do {
//        let url = createLogFileURL(for: type)
//        try await model.writeLogs(as: type, to: url)
//        await MainActor.run {
//          self.logFileDocument = SystemLog.MultiTypeFileDocument(file: url, fileType: type)
//          self.showFileExporter = true
//        }
//      } catch {
//        alertMessage = "Failed to write logs to file: \(error.localizedDescription)"
//        showAlert = true
//      }
//    }
//  }
//
//  private func shareLogFile(type: UTType) -> URL {
//    let url = createLogFileURL(for: type)
//    Task {
//      do {
//        try await model.writeLogs(as: type, to: url)
//      } catch {
//      }
//    }
//    return url
//  }
//
//  private func createLogFileURL(for type: UTType) -> URL {
//    let fileName = "\(ProcessInfo.processInfo.processName)-\(Date().timeIntervalSince1970)"
//    let fileExtension = type.fileExtension
//    let fullFile = "\(fileName).\(fileExtension)"
//    return URL.temporaryDirectory.appendingPathComponent(fullFile)
//  }
//
//  private func handleFileExportResult(_ result: Result<URL, Error>) {
//    switch result {
//    case .success:
//      break
//    case .failure(let error):
//      alertMessage = "Failed to export the file: \(error.localizedDescription)"
//      showAlert = true
//    }
//    logFileDocument = nil
//  }
//
//  private func setToPasteBoard(_ string: String) {
//    #if os(macOS)
//      let pasteboard = NSPasteboard.general
//      pasteboard.declareTypes([.string], owner: nil)
//      pasteboard.setString(string, forType: .string)
//    #else
//      UIPasteboard.general.string = string
//    #endif
//  }
//}
//
//extension LogExportScreen {
//  @ToolbarContentBuilder
//  private var toolbarComponents: some ToolbarContent {
//    ToolbarItemGroup(placement: .navigation) {
//      if model.isExporting {
//        overlayProgress
//      }
//      if showToast {
//        copiedConfirmation
//      }
//    }
//  }
//
//  private var overlayProgress: some View {
//    HStack(spacing: 6) {
//      ProgressView()
//        .controlSize(.small)
//      Text("Loading...")
//        .font(.caption.weight(.medium))
//        .foregroundStyle(.secondary)
//    }
//    .padding(.horizontal, 8)
//    .padding(.vertical, 4)
//    .background(Color(.systemGray).opacity(0.15))
//    .clipShape(Capsule())
//    .transition(.scale.combined(with: .opacity))
//  }
//
//  private var copiedConfirmation: some View {
//    HStack(spacing: 4) {
//      Image(systemName: "checkmark.circle.fill")
//        .foregroundStyle(.green)
//      Text("Copied")
//        .font(.caption.weight(.medium))
//    }
//    .padding(.horizontal, 8)
//    .padding(.vertical, 4)
//    .background(Color.green.opacity(0.15))
//    .clipShape(Capsule())
//    .transition(.scale.combined(with: .opacity))
//    .task {
//      try? await Task.sleep(for: .seconds(2))
//      withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
//        showToast = false
//      }
//    }
//  }
//
//  
//
//  private var filterOptions: some View {
//    Section {
//      
//      VStack(alignment: .leading, spacing: 8) {
//        Text("Export format")
//          .font(.subheadline)
//          .foregroundStyle(.secondary)
//
//        Picker("Export filetype", selection: $selectedExport) {
//          ForEach(SystemLog.LogModel.allowedTypes, id: \.self) { type in
//            Text(type.description).tag(type)
//          }
//        }
//        .pickerStyle(.segmented)
//        .labelsHidden()
//        
//        Picker(selection: $model.filter) {
//          ForEach(
//            [
//              OSLogStream.Filter.any,
//              OSLogStream.Filter.category(Bundle.main.bundleIdentifier ?? "unknown.bundle")
//            ]) { filter in
//              Text(filter.description)
//            }
//        } label: {
//          Text("Filter")
//        }
//
//      }
//    } header: {
//      Label("Options", systemImage: "gearshape.fill")
//    } footer: {
//      Text(
//        "When **Exclude system logs** is enabled, only log entries from this app will be included in the export."
//      )
//      .font(.caption)
//    }
//    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.filter)
//  }
//
//  private var actionButtonsSection: some View {
//    Section {
//      SystemLog.ActionButton("Copy to clipboard", systemImage: "doc.on.doc.fill", iconTint: .blue) {
//        copyToClipboard()
//      }
//
//      SystemLog.ActionButton("Export log file", systemImage: "arrow.down.doc.fill", iconTint: .cyan)
//      {
//        exportLogFile(type: selectedExport)
//      }
//
//      ShareLink(item: shareLogFile(type: selectedExport)) {
//        Label {
//          Text("Share log file")
//        } icon: {
//          Image(systemName: "square.and.arrow.up.fill")
//            .symbolRenderingMode(.hierarchical)
//            .foregroundStyle(.green)
//        }
//
//      }
//
//    } header: {
//      Label("Actions", systemImage: "bolt.fill")
//    }
//  }
//}
