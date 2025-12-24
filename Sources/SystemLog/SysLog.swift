import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

import class Foundation.Bundle
import struct OSLog.Logger
import class OSLog.OSLogEntryLog
import struct OSLog.OSLogInterpolation
import struct OSLog.OSLogPrivacy
import class OSLog.OSLogStore
import struct OSLog.OSLogType

public typealias SystemLogger = OSLog.Logger
extension SystemLogger {
  @_spi(SysLog) public static func make(
    file: StaticString = #file,
    subsystem: String = Bundle.main.bundleIdentifier ?? "none.bundle",
    category: StaticString? = nil
  )
    -> SystemLogger
  {
    SystemLogger(
      subsystem: subsystem,
      category: { () -> String in
        category.map(String.init)
          ?? ("\(file)"
          .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first?
          .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).last).flatMap(
            String.init)
          ?? "\(file)"
      }()
    )
  }

}

extension String {
  public init<T>(dump v: @autoclosure @escaping () -> T) {
    var str: String = ""
    dump(v(), to: &str)
    self = str
  }
}

// MARK: - Persistent Disk Logging

/// Actor that handles writing log entries to a persistent file on disk.
/// Enable via UserDefaults key "debug.persistentLogging".
public actor PersistentLogWriter {
  /// Shared instance for the persistent log writer
  public static let shared = PersistentLogWriter()

  /// UserDefaults key for enabling persistent logging (matches SettingsKeys.persistentLoggingEnabled)
  public static let userDefaultsKey = "debug.persistentLogging"

  private var fileHandle: FileHandle?
  private let dateFormatter: ISO8601DateFormatter
  private var isEnabled: Bool = false

  private init() {
    self.dateFormatter = ISO8601DateFormatter()
    self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    // Read initial state from UserDefaults
    self.isEnabled = UserDefaults.standard.bool(forKey: Self.userDefaultsKey)
    if isEnabled {
      Task { await self.openLogFile() }
    }
  }

  /// Returns the URL to the persistent log file
  public nonisolated var logFileURL: URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    let logsDir = appSupport.appendingPathComponent("Logs", isDirectory: true)
    return logsDir.appendingPathComponent("persistent.log")
  }

  /// Check if persistent logging is currently enabled
  public var persistentLoggingEnabled: Bool {
    isEnabled
  }

  /// Update the enabled state (call when UserDefaults changes)
  public func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    if enabled {
      openLogFile()
    } else {
      closeLogFile()
    }
  }

  /// Refresh enabled state from UserDefaults
  public func refreshEnabledState() {
    let enabled = UserDefaults.standard.bool(forKey: Self.userDefaultsKey)
    setEnabled(enabled)
  }

  /// Write a log entry to the persistent file
  public func log(
    level: OSLogType,
    subsystem: String,
    category: String,
    message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    guard isEnabled, let handle = fileHandle else { return }

    let timestamp = dateFormatter.string(from: Date())
    let levelString = level.description
    let fileName =
      file.split(separator: "/").last.map(String.init) ?? file

    let logLine =
      "[\(timestamp)] [\(levelString)] [\(subsystem)/\(category)] \(fileName):\(line) \(function) - \(message)\n"

    if let data = logLine.data(using: .utf8) {
      do {
        try handle.write(contentsOf: data)
      } catch {
        // Silently fail - don't log errors about logging
      }
    }
  }

  /// Flush pending writes to disk
  public func flush() {
    try? fileHandle?.synchronize()
  }

  /// Clear the log file
  public func clearLog() throws {
    closeLogFile()
    try FileManager.default.removeItem(at: logFileURL)
    if isEnabled {
      openLogFile()
    }
  }

  /// Read the current log file contents
  public nonisolated func readLog() throws -> String {
    try String(contentsOf: logFileURL, encoding: .utf8)
  }

  /// Get the size of the log file in bytes
  public nonisolated func logFileSize() -> UInt64 {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path)
    else { return 0 }
    return attrs[.size] as? UInt64 ?? 0
  }

  private func openLogFile() {
    let url = logFileURL
    let fm = FileManager.default

    // Create directory if needed
    let logsDir = url.deletingLastPathComponent()
    if !fm.fileExists(atPath: logsDir.path) {
      try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }

    // Create file if needed
    if !fm.fileExists(atPath: url.path) {
      fm.createFile(atPath: url.path, contents: nil)
    }

    // Open for appending
    do {
      let handle = try FileHandle(forWritingTo: url)
      try handle.seekToEnd()
      self.fileHandle = handle

      // Write session start marker
      let timestamp = dateFormatter.string(from: Date())
      let marker = "\n=== Session started at \(timestamp) ===\n"
      if let data = marker.data(using: .utf8) {
        try handle.write(contentsOf: data)
      }
    } catch {
      self.fileHandle = nil
    }
  }

  private func closeLogFile() {
    try? fileHandle?.synchronize()
    try? fileHandle?.close()
    fileHandle = nil
  }
}

extension OSLogType: @retroactive CustomStringConvertible {
  public var description: String {
    switch self {
    case .debug: return "DEBUG"
    case .info: return "INFO"
    case .default: return "DEFAULT"
    case .error: return "ERROR"
    case .fault: return "FAULT"
    default: return "UNKNOWN"
    }
  }
}

// MARK: - SystemLogger Disk Logging Extension

extension SystemLogger {
  /// Log a message to both OSLog and the persistent disk log (if enabled)
  public func logPersistent(
    level: OSLogType,
    _ message: @autoclosure () -> String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    let msg = message()

    // Log to OSLog
    self.log(level: level, "\(msg)")

    // Log to disk if enabled
    Task {
      await PersistentLogWriter.shared.log(
        level: level,
        subsystem: "app",
        category: "default",
        message: msg,
        file: file,
        function: function,
        line: line
      )
    }
  }
}
public struct SourceLocation {
  public init(file: String, function: String, line: Int, column: Int) {
    self.file = file
    self.function = function
    self.line = line
    self.column = column
  }
  public let file: String
  public let function: String
  public let line: Int
  public let column: Int
}
/// A struct that provides a convenient way to report errors.
public struct Reporter<E: Error> {
  /// Creates a new `Reporter` instance.
  ///
  /// - Parameter receivers: A list of closures that will be called when an error is reported.
  public init(receivers: (E, SourceLocation) -> Void...) {
    self.receivers = receivers
  }
  private let receivers: [(E, SourceLocation) -> Void]
  /// Calls an operation and reports any errors that occur.
  ///
  /// - Parameters:
  ///   - isolation: The actor isolation to use for the operation.
  ///   - file: The file where the operation is called.
  ///   - function: The function where the operation is called.
  ///   - line: The line where the operation is called.
  ///   - column: The column where the operation is called.
  ///   - operation: The operation to call.
  /// - Returns: The result of the operation.
  /// - Throws: The error that occurred during the operation.
  @discardableResult
  public func callAsFunction<V: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    column: Int = #column,
    @_inheritActorContext(always) _ operation: sending @isolated(any) () async throws(E) -> V
  ) async throws(E) -> V {
    let sl = SourceLocation(file: file, function: function, line: line, column: column)
    do {
      return try await operation()
    } catch {
      if error is CancellationError {
        throw error
      }
      for receiver in receivers {
        receiver(error, sl)
      }
      throw error
    }
  }
  /// Calls an operation and reports any errors that occur.
  ///
  /// - Parameters:
  ///   - file: The file where the operation is called.
  ///   - function: The function where the operation is called.
  ///   - line: The line where the operation is called.
  ///   - column: The column where the operation is called.
  ///   - operation: The operation to call.
  /// - Returns: The result of the operation.
  /// - Throws: The error that occurred during the operation.
  @discardableResult
  public func callAsFunction<V>(
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    column: Int = #column,
    _ operation: () throws(E) -> V
  ) throws(E) -> V {
    let sl = SourceLocation(file: file, function: function, line: line, column: column)
    do {
      return try operation()
    } catch {
      if error is CancellationError {
        throw error
      }
      for receiver in receivers {
        receiver(error, sl)
      }
      throw error
    }
  }
  /// Calls an operation and reports any errors that occur.
  ///
  /// - Parameters:
  ///   - isolation: The actor isolation to use for the operation.
  ///   - file: The file where the operation is called.
  ///   - function: The function where the operation is called.
  ///   - line: The line where the operation is called.
  ///   - column: The column where the operation is called.
  ///   - operation: The operation to call.
  ///   - catchBlock: A closure that is called when an error occurs.
  /// - Returns: The result of the operation, or `nil` if an error occurs.
  @discardableResult
  public func callAsFunction<V: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    column: Int = #column,
    @_inheritActorContext(always) _ operation: sending @isolated(any) () async throws(E) -> V,
    catch catchBlock: (_ error: E) -> Void
  ) async -> V? {
    let sl = SourceLocation(file: file, function: function, line: line, column: column)
    do {
      return try await operation()
    } catch {
      if error is CancellationError {
        return nil
      }
      for receiver in receivers {
        receiver(error, sl)
      }
      catchBlock(error)
      return nil
    }
  }
  /// Calls an operation and reports any errors that occur.
  ///
  /// - Parameters:
  ///   - file: The file where the operation is called.
  ///   - function: The function where the operation is called.
  ///   - line: The line where the operation is called.
  ///   - column: The column where the operation is called.
  ///   - operation: The operation to call.
  ///   - catchBlock: A closure that is called when an error occurs.
  /// - Returns: The result of the operation, or `nil` if an error occurs.
  @discardableResult
  public func callAsFunction<V>(
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    column: Int = #column,
    _ operation: () throws(E) -> V,
    catch catchBlock: (_ error: E) -> Void
  ) -> V? {
    let sl = SourceLocation(file: file, function: function, line: line, column: column)
    do {
      return try operation()
    } catch {
      if error is CancellationError {
        return nil
      }
      for receiver in receivers {
        receiver(error, sl)
      }
      catchBlock(error)
      return nil
    }
  }
}

private let logger = SystemLog.make()
public enum SystemLog {
  public static func make(file: StaticString = #file, category: StaticString? = nil) -> SystemLogger
  {
    Logger.make(file: file, category: category)
  }
  public struct Viewer: View {
    @State private var model: LogModel = .shared
    public init() {}
    public var body: some View {
      NavigationStack {
        LogExportScreen(model: model)
      }
    }
  }

  @Observable
  fileprivate final class LogModel {
    @MainActor
    static var shared: LogModel = {
      defer {
        logger.log(level: .info, "SystemLog ready")
      }
      return LogModel()
    }()

    var logs: [LogRepresentation] = []
    var error: (any Error)?
    struct Filter: Hashable, Sendable {
      init(
        excludeSystemLogs: Bool = true,
        filterType: FilterType = .preset,
        specificDate: Date = Date(),
        dateRangeStart: Date = Date(),
        dateRangeFinish: Date = Date(),
        hourRangeStart: Date = Date().addingTimeInterval(-3600),
        hourRangeFinish: Date = Date(),
        selectedPreset: Preset = .minutesFive
      ) {
        self.excludeSystemLogs = excludeSystemLogs
        self.filterType = filterType
        self.specificDate = specificDate
        self.dateRangeStart = dateRangeStart
        self.dateRangeFinish = dateRangeFinish
        self.hourRangeStart = hourRangeStart
        self.hourRangeFinish = hourRangeFinish
        self.selectedPreset = selectedPreset
      }
      var excludeSystemLogs: Bool = true
      var filterType: SystemLog.LogModel.FilterType
      var specificDate: Date
      var dateRangeStart: Date
      var dateRangeFinish: Date
      var hourRangeStart: Date
      var hourRangeFinish: Date
      var selectedPreset: Preset
    }
    var filter: Filter = .init()
    var exportState: ExportState = .ready
    static let allowedTypes: [UTType] = [.log, .json, .plainText, .text, .commaSeparatedText]
    init() {
    }
  }

  enum Level: String, Sendable, Codable, CustomStringConvertible {
    case undefined
    case debug
    case info
    case notice
    case error
    case fault
    case unknown

    var description: String {
      switch self {
      case .undefined:
        return "Undefined"
      case .debug:
        return "Debug"
      case .info:
        return "Info"
      case .notice:
        return "Notice"
      case .error:
        return "Error"
      case .fault:
        return "Fault"
      case .unknown:
        return "Unknown"
      }
    }
    var color: Color {
      switch self {
      case .undefined:
        return .gray
      case .debug:
        return .green
      case .info:
        return .blue
      case .notice:
        return Color(PlatformColor.predatedCyan)
      case .error:
        return .orange
      case .fault:
        return .red
      case .unknown:
        return .clear
      }
    }
    var sfSymbol: String {
      switch self {
      case .undefined:
        return "exclamationmark"
      case .debug:
        return "stethoscope"
      case .info:
        return "info"
      case .notice:
        return "bell.fill"
      case .error:
        return "exclamationmark.2"
      case .fault:
        return "exclamationmark.3"
      case .unknown:
        return "questionmark"
      }
    }
  }

  enum Delimiter: String {
    case comma = ","
    case semicolon = ";"
    case tab = "\t"
    case pipe = "|"
    internal func escape(_ value: String) -> String {
      switch self {
      case .comma:
        return value.replacingOccurrences(of: self.rawValue, with: "\\\(self.rawValue)")
      case .semicolon:
        return value.replacingOccurrences(of: self.rawValue, with: "\\\(self.rawValue)")
      case .tab:
        return value.replacingOccurrences(of: self.rawValue, with: "\\\(self.rawValue)")
      case .pipe:
        return value.replacingOccurrences(of: self.rawValue, with: "\\\(self.rawValue)")
      }
    }
  }

  struct ActionButton: View {
    private let title: String

    private let systemImage: String

    private let action: () -> Void
    private let tint: Color?
    init(
      _ title: String,
      systemImage: String,
      iconTint: Color? = nil,
      action: @escaping () -> Void
    ) {
      self.title = title
      self.systemImage = systemImage
      self.action = action
      self.tint = iconTint
    }

    var body: some View {
      Button(action: action) {
        Label {
          Text(title)
        } icon: {
          Image(systemName: systemImage)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint ?? .accentColor)
        }

      }
      .buttonStyle(.borderless)
      .accessibilityLabel(title)
    }
  }

  struct FilterSheet: View {
    @Binding var selectedCategories: Set<String>

    @Binding var selectedLevels: Set<Level>

    let categories: [String]

    let levels: [Level]

    var body: some View {
      NavigationStack {
        Form {
          Section {
            HStack {
              Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                  if selectedCategories.count == categories.count {
                    selectedCategories.removeAll()
                  } else {
                    selectedCategories = Set(categories)
                  }
                }
              } label: {
                Label(
                  selectedCategories.count == categories.count ? "Deselect All" : "Select All",
                  systemImage: selectedCategories.count == categories.count
                    ? "checkmark.circle.fill" : "circle"
                )
              }
              .buttonStyle(.bordered)

              Spacer()

              MultiSelectPicker(
                title: "Categories",
                options: categories,
                selectedOptions: $selectedCategories
              )
            }
          } header: {
            Label("Categories", systemImage: "folder.fill")
          }

          Section {
            HStack {
              Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                  if selectedLevels.count == levels.count {
                    selectedLevels.removeAll()
                  } else {
                    selectedLevels = Set(levels)
                  }
                }
              } label: {
                Label(
                  selectedLevels.count == levels.count ? "Deselect All" : "Select All",
                  systemImage: selectedLevels.count == levels.count
                    ? "checkmark.circle.fill" : "circle"
                )
              }
              .buttonStyle(.bordered)

              Spacer()

              MultiSelectPicker(
                title: "Levels",
                options: levels,
                selectedOptions: $selectedLevels
              )
            }
          } header: {
            Label("Log Levels", systemImage: "tag.fill")
          }
        }
        .navigationTitle("Filters")
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              // Sheet dismisses automatically
            }
          }
        }
      }
    }
  }

  struct VerticalLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
      VStack(alignment: .leading) {
        configuration.label
          .fontWeight(.bold)
        configuration.content
      }
      .padding(.bottom, 4)
    }
  }

  struct LogCell: View {
    private let log: LogRepresentation
    @State private var isExpanded: Bool = false

    fileprivate init(for log: LogRepresentation) {
      self.log = log
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        headerSection
          .padding(.bottom, 8)

        Divider()
          .overlay(
            LinearGradient(
              colors: [log.level.color, log.level.color.opacity(0.3)],
              startPoint: .leading,
              endPoint: .trailing
            )
          )
          .padding(.bottom, 8)

        logDetailsSection
      }
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(log.level.color.opacity(0.08))
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(log.level.color.opacity(0.2), lineWidth: 1)
          )
      )
      .contentShape(Rectangle())
      .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isExpanded)
    }

    private var headerSection: some View {
      HStack(spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
              LinearGradient(
                colors: [log.level.color, log.level.color.opacity(0.8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
            .frame(width: 32, height: 32)
            .shadow(color: log.level.color.opacity(0.3), radius: 4, x: 0, y: 2)

          Image(systemName: log.level.sfSymbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
        }

        VStack(alignment: .leading, spacing: 4) {
          Text(log.date.formatted(date: .abbreviated, time: .standard))
            .font(.system(.subheadline, design: .rounded, weight: .medium))
            .foregroundStyle(.primary)

          HStack(spacing: 6) {
            Image(systemName: "tag.fill")
              .font(.system(size: 9))
              .foregroundStyle(.secondary)
            Text(log.level.description)
              .font(.system(.caption, design: .rounded, weight: .semibold))
              .foregroundStyle(log.level.color)
          }
        }

        Spacer()
      }
    }

    private var logDetailsSection: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Label {
            Text(log.subsystem)
              .font(.system(.caption, design: .monospaced, weight: .semibold))
              .foregroundStyle(.primary)
          } icon: {
            Image(systemName: "cube.fill")
              .font(.system(size: 10))
          }
          .foregroundStyle(.primary)

          Label {
            Text(log.category)
              .font(.system(.caption, design: .monospaced))
          } icon: {
            Image(systemName: "folder.fill")
              .font(.system(size: 10))
              .foregroundStyle(.purple)
          }
          .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)

        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("Message")
              .font(.system(.caption2, weight: .bold))
              .foregroundStyle(.secondary)
              .textCase(.uppercase)
            Spacer()
            if log.composedMessage.count > 100 {
              Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                  isExpanded.toggle()
                }
              } label: {
                Image(
                  systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
            }
          }

          Text(log.composedMessage)
            .font(.system(.callout, design: .default))
            .foregroundStyle(.primary)
            .lineLimit(isExpanded ? nil : 3)
            .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(white: 0.5, opacity: 0.05))
        )
      }
    }
  }

  fileprivate struct LogExportScreen: View {
    fileprivate init(model: LogModel) {
      self.model = model
    }
    @Bindable private var model: LogModel
    @State private var showFileExporter: Bool = false
    @State private var logFileDocument: MultiTypeFileDocument?
    @State private var logFileDocumentType: UTType = .log
    @State private var selectedExport: UTType = .log
    @State private var showAlert: Bool = false
    @State private var alertMessage: String = ""
    @State private var showToast: Bool = false

    enum Destination {
      case logList
    }
    @State var destination: Destination?

    var body: some View {
      Form {
        actionButtonsSection
        filterTypeSection
        filterOptions

        Section {
          Button {
            destination = .logList
          } label: {
            HStack {
              Label("View logs", systemImage: "list.bullet.rectangle.fill")
                .symbolRenderingMode(.hierarchical)
              Spacer()
              if model.isExporting {
                ProgressView()
                  .controlSize(.small)
              } else {
                Image(systemName: "chevron.right")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
          .buttonStyle(.borderless)
          .disabled(model.isExporting)
        } header: {
          Label("Viewing", systemImage: "eye.fill")
        } footer: {
          if model.isExporting {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
              Text("Loading log entries...")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Export Logs")
      .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.isExporting)
      .toolbar { toolbarComponents }
      .task { model.fetchLogEntries() }
      .onChange(of: model.filter, initial: true) {
        Task { model.fetchLogEntries() }
      }
      .fileExporter(
        isPresented: $showFileExporter,
        document: logFileDocument,
        contentType: selectedExport
      ) { result in
        handleFileExportResult(result)
      }
      .alert(
        "Error",
        isPresented: $showAlert
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(alertMessage)
      }
      .navigationDestination(item: $destination) { it in
        switch it {
        case .logList:
          LogListScreen(model: model)
        }
      }
    }
  }
  final class MultiTypeFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.log, .json, .plainText, .commaSeparatedText]

    let file: URL

    let fileType: UTType

    init(file: URL, fileType: UTType) {
      self.file = file
      self.fileType = fileType
    }

    required init(configuration _: ReadConfiguration) throws {
      throw NSError(
        domain: "com.example.logexporter",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "This document type cannot be read."]
      )
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
      return try FileWrapper(url: file)
    }
  }

  struct LogListScreen: View {
    @State private var searchText: String = ""
    @Bindable fileprivate var model: LogModel
    private var logs: [LogRepresentation] {
      model.logs
    }

    @State private var selectedCategories: Set<String> = []

    @State private var selectedLevels: Set<Level> = []

    @State private var isFilterSheetPresented: Bool = false
    @State private var hoveredLogId: String?

    @Environment(\.dismiss) private var dismiss

    private var categories: [String] {
      Array(Set(logs.map { $0.category })).sorted()
    }

    private var levels: [Level] {
      Array(Set(logs.map { $0.level })).sorted { $0.rawValue < $1.rawValue }
    }

    private var filteredLogs: [LogRepresentation] {
      logs.filter { log in
        (searchText.isEmpty || log.composedMessage.localizedCaseInsensitiveContains(searchText))
          && (selectedCategories.isEmpty || selectedCategories.contains(log.category))
          && (selectedLevels.isEmpty || selectedLevels.contains(log.level))
      }
    }

    private var hasActiveFilters: Bool {
      !selectedCategories.isEmpty || !selectedLevels.isEmpty
    }

    fileprivate init(model: LogModel) {
      self.model = model
    }

    var body: some View {
      List {
        ForEach(filteredLogs) { log in
          LogCell(for: log)
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            #if os(macOS)
              .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                  hoveredLogId = hovering ? log.id : nil
                }
              }
            #endif
        }
      }
      .listStyle(.plain)
      .overlay {
        if let error = model.error {
          errorOverlay(error: error)
        }
      }
      .navigationTitle("Logs")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .searchable(text: $searchText, prompt: "Search messages...")
      .toolbar {
        #if os(macOS)
          ToolbarItem(placement: .navigation) {
            Button {
              dismiss()
            } label: {
              Label("Back", systemImage: "chevron.left")
                .labelStyle(.iconOnly)
            }
            .help("Back to Export")
          }
        #endif

        ToolbarItemGroup(placement: .automatic) {
          if !logs.isEmpty {
            filterButton
          }
        }
      }
      .overlay {
        if filteredLogs.isEmpty && model.error == nil {
          emptyStateView
        }
      }
      .sheet(isPresented: $isFilterSheetPresented) {
        FilterSheet(
          selectedCategories: $selectedCategories,
          selectedLevels: $selectedLevels,
          categories: categories,
          levels: levels
        )
        #if os(iOS)
          .presentationDetents([.height(200)])
        #endif
      }
    }

    private var filterButton: some View {
      Button {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
          isFilterSheetPresented.toggle()
        }
      } label: {
        Label(
          "Filter",
          systemImage: hasActiveFilters
            ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
        )
        .symbolRenderingMode(.hierarchical)
      }
      .help("Filter logs by category and level")
      .keyboardShortcut("f", modifiers: .command)
    }

    private func errorOverlay(error: Error) -> some View {
      VStack(spacing: 16) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 48))
          .foregroundStyle(.orange)
          .symbolEffect(.bounce, value: model.error?.localizedDescription)

        Text("Error loading logs")
          .font(.title2)
          .fontWeight(.bold)

        Button {
          withAnimation {
            model.error = nil
            model.fetchLogEntries()
          }
        } label: {
          Label("Retry", systemImage: "arrow.clockwise")
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)

        ScrollView(.vertical) {
          Text(error.localizedDescription)
            .lineLimit(nil)
            .font(Font.body.monospaced())
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.5, opacity: 0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
      }
      .padding()
      .transition(.scale.combined(with: .opacity))
    }

    private var emptyStateView: some View {
      VStack(spacing: 20) {
        Image(systemName: searchText.isEmpty ? "tray" : "magnifyingglass")
          .font(.system(size: 64))
          .foregroundStyle(.secondary)
          .symbolEffect(.pulse, options: .repeating)

        Text(searchText.isEmpty ? "No log entries found" : "No matching logs")
          .font(.title2)
          .fontWeight(.bold)

        if hasActiveFilters {
          Button {
            withAnimation {
              selectedCategories.removeAll()
              selectedLevels.removeAll()
            }
          } label: {
            Label("Clear Filters", systemImage: "xmark.circle")
          }
          .buttonStyle(.bordered)
        }
      }
      .transition(.scale.combined(with: .opacity))
    }
  }

  struct MultiSelectPicker<T: Hashable & CustomStringConvertible>: View {
    let title: String

    let options: [T]

    @Binding var selectedOptions: Set<T>

    var body: some View {
      Menu {
        ForEach(options, id: \.self) { option in
          Button(action: {
            toggleSelection(for: option)
          }) {
            Label(
              option.description,
              systemImage: selectedOptions.contains(option) ? "checkmark.square" : "square"
            )
          }
        }
      } label: {
        HStack {
          Text(title)
          Spacer()
          Text(selectedOptions.isEmpty ? "None" : "\(selectedOptions.count) selected")
            .foregroundColor(.gray)
        }
      }
    }

    private func toggleSelection(for option: T) {
      if selectedOptions.contains(option) {
        selectedOptions.remove(option)
      } else {
        selectedOptions.insert(option)
      }
    }
  }
}

extension OSLogEntryLog: @retroactive Identifiable {}

extension OSLogEntryLog.Level {
  fileprivate var level: SystemLog.Level {
    switch self {
    case .undefined:
      .undefined
    case .debug:
      .debug
    case .info:
      .info
    case .notice:
      .notice
    case .error:
      .error
    case .fault:
      .fault
    @unknown default:
      .unknown
    }
  }
  fileprivate var color: Color {
    switch self {
    case .undefined:
      return .gray
    case .debug:
      return .green
    case .info:
      return .blue
    case .notice:
      return Color(PlatformColor.predatedCyan)
    case .error:
      return .orange
    case .fault:
      return .red
    @unknown default:
      return .clear
    }
  }
  fileprivate var sfSymbol: String {
    switch self {
    case .undefined:
      return "exclamationmark"
    case .debug:
      return "stethoscope"
    case .info:
      return "info"
    case .notice:
      return "bell.fill"
    case .error:
      return "exclamationmark.2"
    case .fault:
      return "exclamationmark.3"
    @unknown default:
      return "questionmark"
    }
  }
}

extension Date {

  fileprivate func createDateTime(hour: Int, minute: Int) -> Date? {
    var components = Calendar.current.dateComponents([.year, .month, .day], from: self)
    components.hour = hour
    components.minute = minute
    return Calendar.current.date(from: components)
  }
}

extension PlatformColor {

  fileprivate static let predatedCyan: PlatformColor = .init(
    red: 50 / 255, green: 173 / 255, blue: 230 / 255, alpha: 1)
}

extension LabeledContentStyle where Self == SystemLog.VerticalLabeledContentStyle {
  fileprivate static var vertical: SystemLog.VerticalLabeledContentStyle { Self() }
}

extension SystemLog.LogExportScreen {
  private func copyToClipboard() {
    let logs = model.logs
    Task { [logs] in
      let logs = SystemLog.LogModel.exportLogs(logs, as: .plainText)
      let contentToPaste = logs.isEmpty ? "Nothing to paste" : logs
      setToPasteBoard(contentToPaste)
      showToast = true
    }
  }

  private func exportLogFile(type: UTType) {
    guard logFileDocument == nil else {
      showFileExporter.toggle()
      return
    }
    Task {
      do {
        let url = createLogFileURL(for: type)
        try await model.writeLogs(as: type, to: url)
        await MainActor.run {
          self.logFileDocument = SystemLog.MultiTypeFileDocument(file: url, fileType: type)
          self.showFileExporter = true
        }
      } catch {
        alertMessage = "Failed to write logs to file: \(error.localizedDescription)"
        showAlert = true
      }
    }
  }

  private func shareLogFile(type: UTType) -> URL {
    let url = createLogFileURL(for: type)
    Task {
      do {
        try await model.writeLogs(as: type, to: url)
      } catch {
      }
    }
    return url
  }

  private func createLogFileURL(for type: UTType) -> URL {
    let fileName = "\(ProcessInfo.processInfo.processName)-\(Date().timeIntervalSince1970)"
    let fileExtension = type.fileExtension
    let fullFile = "\(fileName).\(fileExtension)"
    return URL.temporaryDirectory.appendingPathComponent(fullFile)
  }

  private func handleFileExportResult(_ result: Result<URL, Error>) {
    switch result {
    case .success:
      break
    case .failure(let error):
      alertMessage = "Failed to export the file: \(error.localizedDescription)"
      showAlert = true
    }
    logFileDocument = nil
  }

  private func setToPasteBoard(_ string: String) {
    #if os(macOS)
      let pasteboard = NSPasteboard.general
      pasteboard.declareTypes([.string], owner: nil)
      pasteboard.setString(string, forType: .string)
    #else
      UIPasteboard.general.string = string
    #endif
  }
}

extension SystemLog.LogExportScreen {
  @ToolbarContentBuilder
  private var toolbarComponents: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      if model.isExporting {
        overlayProgress
      }
      if showToast {
        copiedConfirmation
      }
    }
  }

  private var overlayProgress: some View {
    HStack(spacing: 6) {
      ProgressView()
        .controlSize(.small)
      Text("Loading...")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color(.systemGray).opacity(0.15))
    .clipShape(Capsule())
    .transition(.scale.combined(with: .opacity))
  }

  private var copiedConfirmation: some View {
    HStack(spacing: 4) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
      Text("Copied")
        .font(.caption.weight(.medium))
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.green.opacity(0.15))
    .clipShape(Capsule())
    .transition(.scale.combined(with: .opacity))
    .task {
      try? await Task.sleep(for: .seconds(2))
      withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
        showToast = false
      }
    }
  }

  private var filterTypeSection: some View {
    Section {
      Picker(
        "Filter by", selection: $model.filter.filterType
      ) {
        ForEach(SystemLog.LogModel.FilterType.allCases) { type in
          Text(type.description).tag(type)
        }
      }
      .pickerStyle(.segmented)
      filterBySegments
    } header: {
      Label("Time Filter", systemImage: "clock.fill")
    } footer: {
      Text(filterFooterText)
        .font(.caption)
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.filter.filterType)
  }

  private var filterOptions: some View {
    Section {
      Toggle(isOn: $model.filter.excludeSystemLogs) {
        Label("Exclude system logs", systemImage: "line.3.horizontal.decrease.circle")
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Export format")
          .font(.subheadline)
          .foregroundStyle(.secondary)

        Picker("Export filetype", selection: $selectedExport) {
          ForEach(SystemLog.LogModel.allowedTypes, id: \.self) { type in
            Text(type.description).tag(type)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
    } header: {
      Label("Options", systemImage: "gearshape.fill")
    } footer: {
      Text(
        "When **Exclude system logs** is enabled, only log entries from this app will be included in the export."
      )
      .font(.caption)
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.filter.excludeSystemLogs)
  }

  private var actionButtonsSection: some View {
    Section {
      SystemLog.ActionButton("Copy to clipboard", systemImage: "doc.on.doc.fill", iconTint: .blue) {
        copyToClipboard()
      }

      SystemLog.ActionButton("Export log file", systemImage: "arrow.down.doc.fill", iconTint: .cyan)
      {
        exportLogFile(type: selectedExport)
      }

      ShareLink(item: shareLogFile(type: selectedExport)) {
        Label {
          Text("Share log file")
        } icon: {
          Image(systemName: "square.and.arrow.up.fill")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.green)
        }

      }

    } header: {
      Label("Actions", systemImage: "bolt.fill")
    }
  }

  @ViewBuilder
  private var filterBySegments: some View {
    switch model.filter.filterType {
    case .specificDate: specificDateSegment
    case .dateRange: dateRangeSegment
    case .hourRange: hourRangeSegment
    case .preset: presetSegment
    }
  }

  private var specificDateSegment: some View {
    DatePicker(
      "Specific date",
      selection: $model.filter.specificDate,
      in: ...Date.now,
      displayedComponents: .date
    )
  }

  private var dateRangeSegment: some View {
    Group {
      DatePicker(
        "Start date",
        selection: $model.filter.dateRangeStart,
        in: ...model.filter.dateRangeFinish,
        displayedComponents: .date
      )
      DatePicker(
        "Finish date",
        selection: $model.filter.dateRangeFinish,
        in: model.filter.dateRangeStart...,
        displayedComponents: .date
      )
    }
  }

  private var hourRangeSegment: some View {
    Group {
      DatePicker(
        "Specific date",
        selection: $model.filter.specificDate,
        in: ...Date.now,
        displayedComponents: .date
      )
      DatePicker(
        "Start time",
        selection: $model.filter.hourRangeStart,
        in: ...model.filter.hourRangeFinish,
        displayedComponents: .hourAndMinute
      )
      DatePicker(
        "Finish time",
        selection: $model.filter.hourRangeFinish,
        in: model.filter.hourRangeStart...,
        displayedComponents: .hourAndMinute
      )
    }
  }

  private var presetSegment: some View {
    Picker("Recent", selection: $model.filter.selectedPreset) {
      ForEach(SystemLog.LogModel.Preset.allCases, id: \.self) { preset in
        Text("Last \(preset.description)").id(preset)
      }
    }
  }

  private var filterFooterText: String {
    switch model.filter.filterType {
    case .specificDate:
      "Select a specific date to filter logs from that day only. All times are considered within the selected date."
    case .dateRange:
      "Choose a start and end date to filter logs within a specific date range. Logs from both dates will be included."
    case .hourRange:
      "Set a specific date and a range of hours to narrow down logs to a precise time window within the chosen day."
    case .preset:
      "Select a preset option to quickly apply common date and time filters without manual adjustments."
    }
  }
}

extension UTType {
  fileprivate var fileExtension: String {
    switch self {
    case .log: return "log"
    case .json: return "json"
    case .plainText: return "md"
    case .text: return "txt"
    case .commaSeparatedText: return "csv"
    default: return preferredFilenameExtension ?? ""
    }
  }

  fileprivate var description: String {
    switch self {
    case .log: return "Log file"
    case .json: return "JSON"
    case .plainText: return "Markdown"
    case .text: return "Text file"
    case .commaSeparatedText: return "CSV"
    default: return preferredFilenameExtension ?? ""
    }
  }
}

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

#if canImport(UIKit)
  typealias PlatformColor = UIColor
#else
  typealias PlatformColor = NSColor
#endif

extension PlatformColor {
  fileprivate var relativeLuminance: CGFloat {
    let components = self.toRGBAComponents()

    // Convert from sRGB to linear RGB
    let r = components.r < 0.04045 ? components.r / 12.92 : pow((components.r + 0.055) / 1.055, 2.4)
    let g = components.g < 0.04045 ? components.g / 12.92 : pow((components.g + 0.055) / 1.055, 2.4)
    let b = components.b < 0.04045 ? components.b / 12.92 : pow((components.b + 0.055) / 1.055, 2.4)

    // Calculate relative luminance (Y)
    let y = r * 0.2126 + g * 0.7152 + b * 0.0722

    return min(max(y, 0), 1)
  }

  fileprivate func contrastRatio(to otherColor: PlatformColor) -> CGFloat {
    let luminance1 = self.relativeLuminance
    let luminance2 = otherColor.relativeLuminance
    return (max(luminance1, luminance2) + 0.05) / (min(luminance1, luminance2) + 0.05)
  }

}

extension PlatformColor {
  fileprivate struct RGBAComponents {
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
  }

  fileprivate struct HSBComponents {
    var h: CGFloat = 0
    var s: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
  }

  fileprivate func toRGBAComponents() -> RGBAComponents {
    var components = RGBAComponents()

    #if canImport(UIKit)
      let result = self.getRed(
        &components.r,
        green: &components.g,
        blue: &components.b,
        alpha: &components.a
      )
      assert(result, "Failed to get RGBA components from UIColor")
    #else
      if let rgbColor = self.usingColorSpace(.sRGB) {
        rgbColor.getRed(
          &components.r,
          green: &components.g,
          blue: &components.b,
          alpha: &components.a
        )
      } else {
        assertionFailure("Failed to convert color space")
      }
    #endif

    return components
  }

  fileprivate func toHSBComponents() -> HSBComponents {
    var components = HSBComponents()

    #if canImport(UIKit)
      let result = self.getHue(
        &components.h,
        saturation: &components.s,
        brightness: &components.b,
        alpha: &components.a
      )
      assert(result, "Failed to get HSB components from UIColor")
    #else
      if let rgbColor = self.usingColorSpace(.sRGB) {
        rgbColor.getHue(
          &components.h,
          saturation: &components.s,
          brightness: &components.b,
          alpha: &components.a
        )
      } else {
        assertionFailure("Failed to convert color space")
      }
    #endif

    return components
  }

  fileprivate static func dynamicColor(_ block: @escaping () -> PlatformColor) -> PlatformColor {
    #if canImport(UIKit)
      #if os(watchOS)
        return block()
      #else
        return PlatformColor { _ in block() }
      #endif
    #else
      return PlatformColor(name: nil) { _ in block() }
    #endif
  }

}

extension PlatformColor {

  /// Creates a color from # prefix, alpha values, and 3 char shorthand hex values
  fileprivate convenience init?(hex: String) {
    let scanner = Scanner(string: hex)
    scanner.charactersToBeSkipped = nil
    _ = scanner.scanString("#")

    switch scanner.charactersLeft() {
    case 6, 8:
      guard let red = scanner.scanHexByte(),
        let green = scanner.scanHexByte(),
        let blue = scanner.scanHexByte()
      else {
        return nil
      }
      var alpha: UInt8 = 255
      if scanner.charactersLeft() == 2 {
        guard let parsedAlpha = scanner.scanHexByte() else {
          return nil
        }

        alpha = parsedAlpha
      }

      self.init(
        red: CGFloat(red) / 255,
        green: CGFloat(green) / 255,
        blue: CGFloat(blue) / 255,
        alpha: CGFloat(alpha) / 255
      )
    case 3:
      guard let red = scanner.scanHexNibble(),
        let green = scanner.scanHexNibble(),
        let blue = scanner.scanHexNibble()
      else {
        return nil
      }

      self.init(
        red: CGFloat(red) / 15,
        green: CGFloat(green) / 15,
        blue: CGFloat(blue) / 15,
        alpha: 1
      )
    default:
      return nil
    }
  }

  fileprivate func toHex() -> String {
    var components = self.toRGBAComponents()

    // Clamp components to [0.0, 1.0]
    components.r = max(0, min(1, components.r))
    components.g = max(0, min(1, components.g))
    components.b = max(0, min(1, components.b))
    components.a = max(0, min(1, components.a))

    if components.a == 1 {
      // RGB
      return String(
        format: "#%02lX%02lX%02lX",
        Int(round(components.r * 255)),
        Int(round(components.g * 255)),
        Int(round(components.b * 255))
      )
    } else {
      // RGBA
      return String(
        format: "#%02lX%02lX%02lX%02lX",
        Int(round(components.r * 255)),
        Int(round(components.g * 255)),
        Int(round(components.b * 255)),
        Int(round(components.a * 255))
      )
    }
  }

}

extension Scanner {

  fileprivate func scanHexNibble() -> UInt8? {
    guard let character = scanCharacter(), character.isHexDigit else {
      return nil
    }

    return UInt8(String(character), radix: 16)
  }

  fileprivate func scanHexByte() -> UInt8? {
    guard let highNibble = scanHexNibble(), let lowNibble = scanHexNibble() else {
      return nil
    }

    return (highNibble << 4) | lowNibble
  }

  fileprivate func charactersLeft() -> Int {
    return string.count - currentIndex.utf16Offset(in: string)
  }

}

extension PlatformColor {

  fileprivate func lightening(by ratio: CGFloat) -> PlatformColor {
    return .dynamicColor {
      let components = self.toHSBComponents()
      let newBrightness =
        components.b != 0
        ? components.b + (components.b * ratio)
        : ratio

      return PlatformColor(
        hue: components.h,
        saturation: components.s,
        brightness: min(newBrightness, 1),
        alpha: components.a
      )
    }
  }

  fileprivate func darkening(by ratio: CGFloat) -> PlatformColor {
    return .dynamicColor {
      let components = self.toHSBComponents()
      let newBrightness =
        components.b != 1
        ? components.b - (components.b * ratio)
        : 1 - ratio

      return PlatformColor(
        hue: components.h,
        saturation: components.s,
        brightness: max(newBrightness, 0),
        alpha: components.a
      )
    }
  }

}

#if canImport(SwiftUI)
  import SwiftUI

  @available(macOS 11.0, iOS 14.0, tvOS 14.0, macCatalyst 14.0, watchOS 7.0, *)
  extension Color {

    fileprivate var relativeLuminance: CGFloat {
      PlatformColor(self).relativeLuminance
    }

    fileprivate init?(hex: String) {
      guard let color = PlatformColor(hex: hex) else {
        return nil
      }

      self.init(color)
    }

    fileprivate func toHex() -> String {
      return PlatformColor(self).toHex()
    }

    fileprivate func contrastRatio(to otherColor: Color) -> CGFloat {
      return PlatformColor(self).contrastRatio(to: PlatformColor(otherColor))
    }

    fileprivate func lightening(by ratio: CGFloat) -> Color {
      return Color(
        PlatformColor(self).lightening(by: ratio)
      )
    }

    fileprivate func darkening(by ratio: CGFloat) -> Color {
      return Color(
        PlatformColor(self).darkening(by: ratio)
      )
    }

  }
#endif

extension SystemLog.LogModel {
  fileprivate enum ExportState {
    case ready
    case processing
    case completed
    case failed
  }
  fileprivate var isExporting: Bool {
    exportState == .processing
  }
  fileprivate enum FilterType: CustomStringConvertible, CaseIterable, Hashable, Identifiable {
    case preset
    case specificDate
    case dateRange
    case hourRange
    var id: Self { self }
    var description: String {
      switch self {
      case .specificDate: return "Date"
      case .dateRange: return "Date range"
      case .hourRange: return "Time range"
      case .preset: return "Recent"
      }
    }
  }
  fileprivate enum Preset: CustomStringConvertible, CaseIterable {
    case minutesFive
    case minutesTen
    case minutesFifteen
    case minutesThirty
    case hourOne
    case hoursSix
    case hoursTwelve
    case hoursTwentyFour
    var description: String {
      switch self {
      case .minutesFive: return "5 minutes"
      case .minutesTen: return "10 minutes"
      case .minutesFifteen: return "15 minutes"
      case .minutesThirty: return "30 minutes"
      case .hourOne: return "1 hour"
      case .hoursSix: return "6 hours"
      case .hoursTwelve: return "12 hours"
      case .hoursTwentyFour: return "24 hours"
      }
    }
    internal var presetDate: Date {
      return Date().addingTimeInterval(-timeInterval)
    }
    private var timeInterval: TimeInterval {
      let minute: TimeInterval = 60
      let hour: TimeInterval = 3600
      switch self {
      case .minutesFive: return 5 * minute
      case .minutesTen: return 10 * minute
      case .minutesFifteen: return 15 * minute
      case .minutesThirty: return 30 * minute
      case .hourOne: return hour
      case .hoursSix: return 6 * hour
      case .hoursTwelve: return 12 * hour
      case .hoursTwentyFour: return 24 * hour
      }
    }
  }
}

extension SystemLog.LogModel {
  fileprivate enum LoggerError: Error, LocalizedError {
    case failedToFetch
    case failedToWriteFile
    case unsupportedFormatType
    var errorDescription: String? {
      switch self {
      case .failedToFetch:
        return NSLocalizedString(
          "Failed to fetch logs.",
          comment: "Failed to fetch logs.")
      case .failedToWriteFile:
        return NSLocalizedString(
          "Failed to write log file.",
          comment: "Failed to write log file.")
      case .unsupportedFormatType:
        return NSLocalizedString(
          "Unsupported filed type selected - only .log, .plaintext, .commaSeparatedValue, or .json are allowed.",
          comment: "Unsupported filed type selected.")
      }
    }
  }
}

extension SystemLog.LogModel {

  fileprivate func setLogs(to logs: [LogRepresentation]) {
    self.logs = logs
    self.exportState = logs.isEmpty ? .failed : .completed
  }

  @MainActor
  fileprivate func fetchLogEntries() {
    self.exportState = .processing
    Task { @MainActor in
      do {
        let it = filter
        self.logs = try await Task { @BGActor @Sendable [filter = it] in
          let logPredicate: NSPredicate? = Self.getLogPredicate(
            filter: filter, for: filter.excludeSystemLogs ? Bundle.main : nil)
          let store = try OSLogStore(scope: .currentProcessIdentifier)
          return
            try store
            .getEntries(matching: logPredicate)
            .compactMap { $0 as? OSLogEntryLog }
            .map { LogRepresentation(entry: $0) }
        }.value

      } catch {
        self.error = error
      }
    }

  }
  fileprivate static func exportLogs(
    _ logs: [LogRepresentation], as format: UTType, csvDelimiter: SystemLog.Delimiter = .comma
  ) -> String {
    guard Self.allowedTypes.contains(format) else {
      return "Unsupported export format."
    }

    switch format {
    case .json:
      return logEntriesToJSON(logEntries: logs)
    case .commaSeparatedText:
      return logEntriesToCSV(logEntries: logs, delimiter: csvDelimiter)
    case .plainText, .log:
      return logEntriesToString(logEntries: logs)
    default:
      return ""
    }
  }
  @MainActor
  fileprivate func writeLogs(as format: UTType, to url: URL) async throws {
    guard Self.allowedTypes.contains(format) else {
      logger.error("Unsupported export format: \(format, privacy: .public)")
      throw LoggerError.unsupportedFormatType
    }
    let logs = self.logs
    let task = Task { @BGActor [logs] in
      let logString = Self.exportLogs(logs, as: format)
      try logString.write(to: url, atomically: true, encoding: .utf8)
    }
    do {
      try await task.value
      self.exportState = .completed
    } catch {
      logger.error("Failed file export: \(error, privacy: .public)")
      self.exportState = .failed
      throw LoggerError.failedToWriteFile
    }
  }
}

extension SystemLog.LogModel {
  private static func getLogPredicate(filter: Filter, for bundle: Bundle?) -> NSPredicate? {
    switch filter.filterType {
    case .specificDate:
      return datePredicate(for: filter.specificDate, and: bundle)
    case .dateRange:
      return datePredicate(from: filter.dateRangeStart, to: filter.dateRangeFinish, and: bundle)
    case .hourRange:
      guard let (startDate, endDate) = getHourRangeDates(filter: filter) else { return nil }
      return datePredicate(from: startDate, to: endDate, and: bundle)
    case .preset:
      let startDate = filter.selectedPreset.presetDate
      return datePredicate(from: startDate, and: bundle)
    }
  }
  private static func getHourRangeDates(filter: Filter) -> (startDate: Date, endDate: Date)? {
    let startHour = Calendar.current.component(.hour, from: filter.hourRangeStart)
    let startMinute = Calendar.current.component(.minute, from: filter.hourRangeStart)
    let finishHour = Calendar.current.component(.hour, from: filter.hourRangeFinish)
    let finishMinute = Calendar.current.component(.minute, from: filter.hourRangeFinish)

    guard let startDate = filter.specificDate.createDateTime(hour: startHour, minute: startMinute),
      let endDate = filter.specificDate.createDateTime(hour: finishHour, minute: finishMinute)
    else {
      return nil
    }
    return (startDate, endDate)
  }
  private static func datePredicate(for date: Date, and bundle: Bundle?) -> NSPredicate {
    guard let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: date) else {
      return NSPredicate(value: false)
    }
    if let b = bundle?.bundleIdentifier {
      return NSPredicate(
        format: "date >= %@ AND date < %@ AND subsystem = %@",
        date as NSDate,
        nextDay as NSDate,
        b as NSString
      )
    } else {
      return NSPredicate(
        format: "date >= %@ AND date < %@",
        date as NSDate,
        nextDay as NSDate
      )
    }
  }
  private static func datePredicate(
    from startDate: Date, to endDate: Date? = nil, and bundle: Bundle?
  ) -> NSPredicate {
    if let endDate = endDate {
      if let b = bundle?.bundleIdentifier {
        return NSPredicate(
          format: "date >= %@ AND date <= %@ AND subsystem = %@",
          startDate as NSDate,
          endDate as NSDate,
          b as NSString
        )
      } else {
        return NSPredicate(
          format: "date >= %@ AND date <= %@",
          startDate as NSDate,
          endDate as NSDate
        )
      }
    } else {
      if let b = bundle?.bundleIdentifier {
        return NSPredicate(
          format: "date >= %@ AND subsystem = %@",
          startDate as NSDate,
          b as NSString
        )
      } else {
        return NSPredicate(
          format: "date >= %@",
          startDate as NSDate
        )
      }
    }
  }
  private static func logEntriesToString(logEntries logs: [LogRepresentation]) -> String {
    let logStrings = logs.map { entry in
      let message = entry.composedMessage.replacingOccurrences(of: "|", with: "\\|")
      return "\(entry.date) | \(entry.level) | \(entry.subsystem) | \(entry.category) | \(message)"
    }
    return logStrings.joined(separator: "\n")
  }
  private static func logEntriesToJSON(logEntries: [LogRepresentation]) -> String {
    let jsonEncoder = JSONEncoder()
    jsonEncoder.outputFormatting = .prettyPrinted
    if let jsonData = try? jsonEncoder.encode(logEntries),
      let jsonString = String(data: jsonData, encoding: .utf8)
    {
      return jsonString
    }
    return ""
  }
  private static func logEntriesToCSV(
    logEntries: [LogRepresentation], delimiter: SystemLog.Delimiter
  ) -> String {
    let headers = ["Date", "Level", "Subsystem", "Category", "Message"]
    let csvHeaders = headers.joined(separator: delimiter.rawValue)

    let csvStrings = logEntries.map { entry in

      return [
        entry.dateString, entry.level.description, entry.subsystem, entry.category,
        entry.composedMessage,
      ]
      .joined(separator: delimiter.rawValue)
    }
    return ([csvHeaders] + csvStrings).joined(separator: "\n")
  }
}

private struct LogRepresentation: Hashable, Identifiable, Codable {
  let id: String
  let date: Date
  var dateString: String {
    let dateFormatter = ISO8601DateFormatter()
    return dateFormatter.string(from: date)
  }
  let level: SystemLog.Level
  let subsystem: String
  let category: String
  let message: String
  let color: String
  let description: String
  let composedMessage: String
  init(entry: OSLogEntryLog) {
    self.id = "\(ObjectIdentifier(entry))"
    self.date = entry.date
    self.level = entry.level.level
    self.subsystem = entry.subsystem
    self.category = entry.category
    self.message = entry.composedMessage
    self.color = entry.level.color.toHex()
    self.description = entry.description
    self.composedMessage = entry.composedMessage
  }
}

private protocol LoggerCategoryRepresentable: RawRepresentable, Hashable, Equatable
where RawValue == String {}

private actor LoggerCategoryManager {
  private var existingRawValues = Set<String>()
  internal func addCategoryIfNew(_ rawValue: String) -> Bool {
    let lowercasedValue = rawValue.lowercased()
    if existingRawValues.contains(lowercasedValue) {
      return true
    } else {
      existingRawValues.insert(lowercasedValue)
      return false
    }
  }
}
struct LoggerCategory: LoggerCategoryRepresentable, Sendable {
  let rawValue: String
  private static let manager = LoggerCategoryManager()
  init(rawValue: String) {
    self.rawValue = rawValue
    Task {
      _ = await LoggerCategory.manager.addCategoryIfNew(rawValue)
    }
  }
  init(_ value: String) {
    self.init(rawValue: value)
  }
}
extension os.Logger {
  fileprivate init(subsystem: String, category: LoggerCategory) {
    self.init(subsystem: subsystem, category: category.rawValue)
  }
}

@globalActor
private actor BGActor {
  static let shared = BGActor()
}

// MARK: - macOS Window Integration

#if os(macOS)
  extension SystemLog {
    /// Scene for displaying the log viewer in a dedicated window on macOS
    public struct WindowScene: Scene {
      public init() {}

      public var body: some Scene {
        WindowGroup(id: "system-log-viewer") {
          SystemLog.Viewer()
            .frame(minWidth: 800, idealWidth: 1000, minHeight: 600, idealHeight: 800)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .commands {
          LogViewerCommands()
        }
      }
    }

    /// Menu commands for accessing the log viewer
    public struct LogViewerCommands: Commands {
      public init() {}

      public var body: some Commands {
        CommandGroup(after: .windowList) {
          Divider()

          Button("Show Logs") {
            SystemLog.openWindow()
          }
          .keyboardShortcut("l", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) {
          Button("Help") {
            // Keep default help behavior
          }

          Divider()

          Button("Export Logs...") {
            SystemLog.openWindow()
          }
        }
      }
    }

    /// Opens the log viewer window programmatically
    @MainActor
    public static func openWindow() {
      #if canImport(AppKit)
        // Find existing window or create new one
        let windowIdentifier = "system-log-viewer"

        // Try to find existing window first
        for window in NSApp.windows {
          if window.identifier?.rawValue == windowIdentifier {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
          }
        }

        // Create new window if none exists
        let contentView = SystemLog.Viewer()
          .frame(minWidth: 800, idealWidth: 1000, minHeight: 600, idealHeight: 800)

        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hostingController)
        window.identifier = NSUserInterfaceItemIdentifier(rawValue: windowIdentifier)
        window.title = "System Logs"
        window.setContentSize(NSSize(width: 1000, height: 800))
        window.minSize = NSSize(width: 800, height: 600)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        NSApp.activate(ignoringOtherApps: true)
      #endif
    }
  }

  /// Environment key for opening the system log window
  @available(macOS 13.0, *)
  public struct SystemLogWindowKey: EnvironmentKey {
    public static var defaultValue: (() -> Void)? { nil }
  }

  @available(macOS 13.0, *)
  extension EnvironmentValues {
    public var openSystemLogWindow: (() -> Void)? {
      get { self[SystemLogWindowKey.self] }
      set { self[SystemLogWindowKey.self] = newValue }
    }
  }

  // MARK: - SwiftUI App Integration Helper

  extension SystemLog {
    /// Helper to integrate SystemLog window into your SwiftUI App
    ///
    /// Usage in your App:
    /// ```swift
    /// @main
    /// struct MyApp: App {
    ///   var body: some Scene {
    ///     WindowGroup {
    ///       ContentView()
    ///     }
    ///     SystemLog.windowScene
    ///   }
    /// }
    /// ```
    @MainActor
    public static var windowScene: some Scene {
      WindowScene()
    }
  }

  extension Scene {
    /// Adds system log viewer window and commands to your scene
    ///
    /// Usage:
    /// ```swift
    /// @main
    /// struct MyApp: App {
    ///   var body: some Scene {
    ///     WindowGroup {
    ///       ContentView()
    ///     }
    ///     .withSystemLogViewer()
    ///   }
    /// }
    /// ```
    public func withSystemLogViewer() -> some Scene {
      Group {
        self
        SystemLog.WindowScene()
      }
    }
  }

  // MARK: - View Extension for Easy Access

  extension View {
    /// Adds a toolbar button to open the system log viewer window
    ///
    /// Usage:
    /// ```swift
    /// ContentView()
    ///   .systemLogViewerToolbarItem()
    /// ```
    @ViewBuilder
    public func systemLogViewerToolbarItem(
      placement: ToolbarItemPlacement = .automatic, enabled: Bool
    ) -> some View {
      self.toolbar {
        if enabled {
          ToolbarItem(placement: placement) {
            Button {
              SystemLog.openWindow()
            } label: {
              Label("Show Logs", systemImage: "doc.text.magnifyingglass")
            }
            .help("Open System Logs")
          }
        }
      }
    }

    /// Adds a context menu item to open the system log viewer
    ///
    /// Usage:
    /// ```swift
    /// ContentView()
    ///   .systemLogViewerContextMenu()
    /// ```
    public func systemLogViewerContextMenu() -> some View {
      self.contextMenu {
        Button {
          SystemLog.openWindow()
        } label: {
          Label("Show Logs", systemImage: "doc.text.magnifyingglass")
        }
      }
    }
  }

  // MARK: - Standalone Button Component

  extension SystemLog {
    /// A button that opens the system log viewer window
    ///
    /// Usage:
    /// ```swift
    /// SystemLog.OpenButton()
    /// SystemLog.OpenButton(style: .icon)
    /// SystemLog.OpenButton(style: .labeled)
    /// ```
    public struct OpenButton: View {
      public enum Style {
        case icon
        case labeled
        case compact
      }

      private let style: Style

      public init(style: Style = .labeled) {
        self.style = style
      }

      public var body: some View {
        Button {
          SystemLog.openWindow()
        } label: {
          switch style {
          case .icon:
            Image(systemName: "doc.text.magnifyingglass")
              .symbolRenderingMode(.hierarchical)
          case .labeled:
            Label("Show Logs", systemImage: "doc.text.magnifyingglass")
              .symbolRenderingMode(.hierarchical)
          case .compact:
            Label("Logs", systemImage: "doc.text.magnifyingglass")
              .symbolRenderingMode(.hierarchical)
              .labelStyle(.iconOnly)
          }
        }
        .help("Open System Logs")
      }
    }
  }

#endif
