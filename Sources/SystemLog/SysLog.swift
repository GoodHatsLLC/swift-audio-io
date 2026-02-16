import AsyncAlgorithms
public import Foundation
import Observation
public import SwiftUI
public import Tools
import UniformTypeIdentifiers

import class OSLog.OSLogEntryLog
import struct OSLog.OSLogInterpolation
import struct OSLog.OSLogPrivacy
import class OSLog.OSLogStore
import struct OSLog.OSLogType
public import struct os.Logger

public typealias SystemLogger = Logger
extension SystemLogger {
  @_spi(SysLog) public static func make(
    file: StaticString = #file,
    subsystem: String = Bundle.main.bundleIdentifier ?? "none.bundle",
    category: String? = nil
  )
    -> SystemLogger
  {
    SystemLogger(
      subsystem: subsystem,
      category: { () -> String in
        category
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
public struct SourceLocation: Sendable, Hashable {
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
  ) async throws(E) -> V where E: AudioError {
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
  ) throws(E) -> V where E: AudioError {
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

public enum ReportedError: AudioError {
  case cancelled
  case error(ErrorContext)

  public var description: String {
    switch self {
    case .cancelled:
      "Operation cancelled"
    case .error(let context):
      context.description
    }
  }
}

extension Reporter where E == any Error {
  @discardableResult
  public func callAsFunction<V: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    column: Int = #column,
    @_inheritActorContext(always) _ operation:
      sending @isolated(any) () async throws(any Error) -> V
  ) async throws(ReportedError) -> V {
    let sl = SourceLocation(file: file, function: function, line: line, column: column)
    do {
      return try await operation()
    } catch {
      if error is CancellationError {
        throw .cancelled
      }
      for receiver in receivers {
        receiver(error, sl)
      }
      throw .error(ErrorContext(error))
    }
  }

  @discardableResult
  public func callAsFunction<V>(
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    column: Int = #column,
    _ operation: () throws(any Error) -> V
  ) throws(ReportedError) -> V {
    let sl = SourceLocation(file: file, function: function, line: line, column: column)
    do {
      return try operation()
    } catch {
      if error is CancellationError {
        throw .cancelled
      }
      for receiver in receivers {
        receiver(error, sl)
      }
      throw .error(ErrorContext(error))
    }
  }
}

private let logger = SystemLog.make()
public enum SystemLog {
  public static func make(
    file: StaticString = #file, subsystem: String = Bundle.main.bundleIdentifier ?? "none.bundle",
    category: String? = nil
  ) -> SystemLogger {
    Logger.make(
      file: file,
      subsystem: subsystem,
      category: category
    )
  }
  public struct Viewer: View {
    private static let sharedModel = LogModel()

    public init() {}

    public var body: some View {
      LogListScreen(
        model: Self.sharedModel,
        isLoading: Self.sharedModel.exportState == .processing
      )
    }
  }

  @Observable
  @MainActor
  fileprivate final class LogModel {
    var logs: [OSLogStream.LogEntry] = [] {
      didSet {
        let len = max(0, logs.count - oldValue.count)
        let new = logs.suffix(len)
        updateKnownSets(with: new)
      }
    }
    var error: (any Error)?
    var isLoadingOlder: Bool = false
    var loadedStartDate: Date?
    var loadedEndDate: Date?
    var subscriptionID = UUID()
    var knownCategories: Set<String> = []
    var knownSubsystems: Set<String> = []
    let levels = OSLogStream.LogEntry.LogLevel.allCases

    // Track active subscription parameters to avoid redundant refetches on re-navigation.
    private var activeFilter: OSLogStream.Filter?
    private var activeWindow: SystemLog.LogWindow?

    var exportState: ExportState = .ready
    nonisolated static let allowedTypes: [UTType] = [
      .log, .json, .plainText, .text, .commaSeparatedText,
    ]
    init() {
    }

    fileprivate func updateKnownSets<S: Sequence>(
      with entries: S
    ) where S.Element == OSLogStream.LogEntry {
      for entry in entries {
        knownCategories.insert(entry.category ?? "")
        knownSubsystems.insert(entry.subsystem ?? "")
      }
    }
  }

  enum LogWindow: String, CaseIterable, Identifiable, CustomStringConvertible {
    case minutes15
    case hour1
    case hours6
    case all

    var id: Self { self }

    var description: String {
      switch self {
      case .minutes15: return "15 min"
      case .hour1: return "1 hour"
      case .hours6: return "6 hours"
      case .all: return "All"
      }
    }

    var duration: TimeInterval? {
      switch self {
      case .minutes15: return 15 * 60
      case .hour1: return 60 * 60
      case .hours6: return 6 * 60 * 60
      case .all: return nil
      }
    }
  }

  enum DateSortOrder: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: Self { self }

    var label: String {
      switch self {
      case .ascending: return "Oldest First"
      case .descending: return "Newest First"
      }
    }

    var systemImage: String {
      switch self {
      case .ascending: return "arrow.up"
      case .descending: return "arrow.down"
      }
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
        return .cyan
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
    struct Filters: Hashable {
      var minLevel: OSLogStream.LogEntry.LogLevel?
      var categories: Set<String> = []
      var subsystems: Set<String> = []

      var levelInt: Int {
        get {
          minLevel?.nativeIntValue ?? -1
        }
        set {
          minLevel = .init(nativeIntValue: newValue) ?? .undefined
        }
      }

      var filter: OSLogStream.Filter {
        .and(
          [
            minLevel.map { .levelFloor($0) } ?? .any,
            (subsystems).isEmpty ? .any : .and((subsystems).map { .subsystem($0) }),
            (categories).isEmpty ? .any : .and((categories).map { .category($0) }),
          ]
        )
      }

      var isActive: Bool {
        minLevel != nil || !categories.isEmpty || !subsystems.isEmpty
      }

      var activeCount: Int {
        var count = 0
        if minLevel != nil {
          count += 1
        }
        if !subsystems.isEmpty {
          count += 1
        }
        if !categories.isEmpty {
          count += 1
        }
        return count
      }
    }

    fileprivate var model: LogModel
    @Binding var filters: Filters
    @Binding var isDisplayed: Bool
    @State private var newFilters: Filters = .init()
    @State private var categoryQuery: String = ""
    @State private var subsystemQuery: String = ""

    var body: some View {
      NavigationStack {
        Form {
          Section {
            if activeSummaryChips.isEmpty {
              Text("No filters applied.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                  ForEach(activeSummaryChips, id: \.text) { chip in
                    FilterChip(text: chip.text, tint: chip.tint)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          } header: {
            Text("Active Filters")
          }

          Section {
            Picker("Minimum Level", selection: $newFilters.minLevel) {
              Text("Any").tag(OSLogStream.LogEntry.LogLevel?.none)
              ForEach(levelOptions, id: \.self) { level in
                Label(level.description, systemImage: level.sfSymbol)
                  .tag(Optional(level))
              }
            }
            .pickerStyle(.menu)
          } header: {
            Text("Level")
          }

          Section {
            TextField("Search categories", text: $categoryQuery)
              #if os(iOS)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
              #endif

            if filteredCategories.isEmpty {
              Text(categoryQuery.isEmpty ? "No categories available yet." : "No categories match.")
                .foregroundStyle(.secondary)
            } else {
              ForEach(filteredCategories, id: \.self) { category in
                selectionRow(
                  title: category,
                  isSelected: newFilters.categories.contains(category)
                ) {
                  toggleSelection(category, selection: &newFilters.categories)
                }
              }
            }
          } header: {
            FilterSectionHeader(
              title: "Categories",
              selectedCount: newFilters.categories.count,
              totalCount: categoryOptions.count,
              selectAllTitle: categoryQuery.isEmpty ? "All" : "All Matches",
              selectAllEnabled: !filteredCategories.isEmpty,
              clearEnabled: categoryQuery.isEmpty
                ? !newFilters.categories.isEmpty
                : !newFilters.categories.isDisjoint(with: filteredCategories),
              selectAllAction: { selectAllCategories() },
              clearAction: { clearCategories() }
            )
          }

          Section {
            TextField("Search subsystems", text: $subsystemQuery)
              #if os(iOS)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
              #endif

            if filteredSubsystems.isEmpty {
              Text(subsystemQuery.isEmpty ? "No subsystems available yet." : "No subsystems match.")
                .foregroundStyle(.secondary)
            } else {
              ForEach(filteredSubsystems, id: \.self) { subsystem in
                selectionRow(
                  title: subsystem,
                  isSelected: newFilters.subsystems.contains(subsystem)
                ) {
                  toggleSelection(subsystem, selection: &newFilters.subsystems)
                }
              }
            }
          } header: {
            FilterSectionHeader(
              title: "Subsystems",
              selectedCount: newFilters.subsystems.count,
              totalCount: subsystemOptions.count,
              selectAllTitle: subsystemQuery.isEmpty ? "All" : "All Matches",
              selectAllEnabled: !filteredSubsystems.isEmpty,
              clearEnabled: subsystemQuery.isEmpty
                ? !newFilters.subsystems.isEmpty
                : !newFilters.subsystems.isDisjoint(with: filteredSubsystems),
              selectAllAction: { selectAllSubsystems() },
              clearAction: { clearSubsystems() }
            )
          }
        }
        .navigationTitle("Filters")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button {
              isDisplayed = false
            } label: {
              Image(systemName: "xmark")
                .fontWeight(.semibold)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Apply") {
              filters = newFilters
              isDisplayed = false
            }
            .disabled(newFilters == filters)
          }
          ToolbarItem(placement: .primaryAction) {
            Button("Reset") {
              newFilters = .init()
              categoryQuery = ""
              subsystemQuery = ""
            }
            .disabled(newFilters == .init())
          }
        }
      }
      .task {
        newFilters = filters
      }
    }

    private var levelOptions: [OSLogStream.LogEntry.LogLevel] {
      OSLogStream.LogEntry.LogLevel.allCases
    }

    private var categoryOptions: [String] {
      model.knownCategories.compactMap { $0.isEmpty ? nil : $0 }.sorted()
    }

    private var subsystemOptions: [String] {
      model.knownSubsystems.compactMap { $0.isEmpty ? nil : $0 }.sorted()
    }

    private var filteredCategories: [String] {
      filteredValues(categoryOptions, query: categoryQuery, selected: newFilters.categories)
    }

    private var filteredSubsystems: [String] {
      filteredValues(subsystemOptions, query: subsystemQuery, selected: newFilters.subsystems)
    }

    private struct ActiveChip: Hashable {
      let text: String
      let tint: Color
    }

    private var activeSummaryChips: [ActiveChip] {
      var chips: [ActiveChip] = []
      if let minLevel = newFilters.minLevel {
        chips.append(ActiveChip(text: "Min \(minLevel.description)", tint: minLevel.color))
      }
      if !newFilters.categories.isEmpty {
        chips.append(
          ActiveChip(
            text: "\(newFilters.categories.count) categories",
            tint: .blue
          )
        )
      }
      if !newFilters.subsystems.isEmpty {
        chips.append(
          ActiveChip(
            text: "\(newFilters.subsystems.count) subsystems",
            tint: .teal
          )
        )
      }
      return chips
    }

    private func filteredValues(
      _ values: [String],
      query: String,
      selected: Set<String>
    ) -> [String] {
      let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        return values
      }
      let filtered = values.filter { value in
        value.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      }
      let selectedFirst = filtered.filter { selected.contains($0) }
      let remaining = filtered.filter { !selected.contains($0) }
      return selectedFirst + remaining
    }

    private func toggleSelection(_ value: String, selection: inout Set<String>) {
      if !selection.insert(value).inserted {
        selection.remove(value)
      }
    }

    private func selectAllCategories() {
      newFilters.categories.formUnion(filteredCategories)
    }

    private func clearCategories() {
      if categoryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        newFilters.categories = []
      } else {
        newFilters.categories.subtract(filteredCategories)
      }
    }

    private func selectAllSubsystems() {
      newFilters.subsystems.formUnion(filteredSubsystems)
    }

    private func clearSubsystems() {
      if subsystemQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        newFilters.subsystems = []
      } else {
        newFilters.subsystems.subtract(filteredSubsystems)
      }
    }

    private func selectionRow(
      title: String,
      isSelected: Bool,
      action: @escaping () -> Void
    ) -> some View {
      Button(action: action) {
        HStack(spacing: 8) {
          Text(title)
            .font(.callout)
            .foregroundStyle(.primary)
          Spacer()
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
      }
      .buttonStyle(.plain)
    }

    private struct FilterChip: View {
      let text: String
      let tint: Color

      var body: some View {
        Text(text)
          .font(.caption.weight(.semibold))
          .foregroundStyle(tint)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(tint.opacity(0.16), in: Capsule())
      }
    }

    private struct FilterSectionHeader: View {
      let title: String
      let selectedCount: Int
      let totalCount: Int
      let selectAllTitle: String
      let selectAllEnabled: Bool
      let clearEnabled: Bool
      let selectAllAction: () -> Void
      let clearAction: () -> Void

      var body: some View {
        HStack(spacing: 8) {
          Text(title)
          if totalCount > 0 {
            Text("\(selectedCount)/\(totalCount)")
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button(selectAllTitle, action: selectAllAction)
            .disabled(!selectAllEnabled)
          Button("Clear", action: clearAction)
            .disabled(!clearEnabled)
        }
        .font(.caption)
        .textCase(nil)
        .buttonStyle(.borderless)
      }
    }
  }

  struct ExportSheet: View {
    let logs: [OSLogStream.LogEntry]
    @Binding var isDisplayed: Bool
    @State private var selectedFormat: UTType = .json
    @State private var exportedFileURL: URL?
    @State private var isExporting: Bool = false
    @State private var exportError: (any Error)?

    private let supportedFormats: [UTType] = [.json, .commaSeparatedText, .plainText, .log]

    var body: some View {
      NavigationStack {
        Form {
          Section {
            HStack {
              Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
              Text("\(logs.count) log entries")
                .font(.headline)
            }
          } header: {
            Text("Export Summary")
          }

          Section {
            Picker("Format", selection: $selectedFormat) {
              ForEach(supportedFormats, id: \.self) { format in
                Label(format.exportDescription, systemImage: format.exportIcon)
                  .tag(format)
              }
            }
            .pickerStyle(.inline)
            .labelsHidden()
          } header: {
            Text("Export Format")
          }

          if let error = exportError {
            Section {
              Label {
                Text(error.localizedDescription)
                  .font(.caption)
              } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundStyle(.orange)
              }
            }
          }

          Section {
            if isExporting {
              HStack {
                Spacer()
                ProgressView("Preparing export…")
                Spacer()
              }
            } else if let fileURL = exportedFileURL {
              ShareLink(item: fileURL) {
                Label("Share Logs", systemImage: "square.and.arrow.up")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
            } else {
              Button {
                Task {
                  await prepareExport()
                }
              } label: {
                Label("Prepare Export", systemImage: "doc.badge.gearshape")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .disabled(logs.isEmpty)
            }
          }
        }
        .navigationTitle("Export Logs")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button {
              cleanupAndDismiss()
            } label: {
              Image(systemName: "xmark")
                .fontWeight(.semibold)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
          }
        }
        .onChange(of: selectedFormat) { _, _ in
          exportedFileURL = nil
          exportError = nil
        }
      }
    }

    @MainActor
    private func prepareExport() async {
      isExporting = true
      exportError = nil
      exportedFileURL = nil

      do {
        let content = LogModel.exportLogs(logs, as: selectedFormat)
        let fileName =
          "logs_\(Date.now.ISO8601Format()).\(selectedFormat.preferredFilenameExtension ?? "txt")"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        exportedFileURL = tempURL
      } catch {
        exportError = error
      }

      isExporting = false
    }

    private func cleanupAndDismiss() {
      if let url = exportedFileURL {
        try? FileManager.default.removeItem(at: url)
      }
      isDisplayed = false
    }
  }

  struct LogCell: View {
    private let log: OSLogStream.LogEntry
    @State private var isExpanded: Bool = false

    fileprivate init(for log: OSLogStream.LogEntry) {
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
            Text(log.subsystem ?? "")
              .font(.system(.caption, design: .monospaced, weight: .semibold))
              .foregroundStyle(.primary)
          } icon: {
            Image(systemName: "cube.fill")
              .font(.system(size: 10))
          }
          .foregroundStyle(.primary)

          Label {
            Text(log.category ?? "")
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
    @Bindable fileprivate var model: LogModel
    fileprivate var isLoading: Bool = false
    @State private var isFilterSheetPresented: Bool = false
    @State private var isExportSheetPresented: Bool = false
    @State private var window: LogWindow = .all
    @State private var sortOrder: DateSortOrder = .descending
    @State private var filters: FilterSheet.Filters = {
      var filters = FilterSheet.Filters()
      if let bundleId = Bundle.main.bundleIdentifier {
        filters.subsystems = [bundleId]
      }
      return filters
    }()

    fileprivate init(model: LogModel, isLoading: Bool = false) {
      self.model = model
      self.isLoading = isLoading
    }

    private struct SubscriptionKey: Hashable {
      let filters: FilterSheet.Filters
      let window: LogWindow
    }

    private var sortedLogs: [OSLogStream.LogEntry] {
      switch sortOrder {
      case .ascending:
        model.logs
      case .descending:
        model.logs.reversed()
      }
    }

    var body: some View {
      List {
        ForEach(sortedLogs) { log in
          LogCell(for: log)
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .listRowSeparator(.hidden)
        }
      }
      .listStyle(.plain)
      .overlay {
        if isLoading && model.logs.isEmpty {
          loadingOverlay
        } else if let error = model.error {
          errorOverlay(error: error)
        }
      }
      .navigationTitle("Logs")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .task(id: SubscriptionKey(filters: filters, window: window)) {
        await model.subscribe(filter: filters.filter, window: window)
      }
      .toolbar {
        ToolbarItemGroup(placement: .automatic) {
          loadOlderButton
          sortOrderButton
          rangeMenu
          exportButton
          filterButton
        }
      }
      .sheet(isPresented: $isExportSheetPresented) {
        ExportSheet(logs: model.logs, isDisplayed: $isExportSheetPresented)
          #if os(iOS)
            .presentationDetents([.medium])
          #endif
      }
      .sheet(isPresented: $isFilterSheetPresented) {
        FilterSheet(
          model: model,
          filters: $filters,
          isDisplayed: $isFilterSheetPresented
        )
        #if os(iOS)
          .presentationDetents([.medium, .large])
        #endif
      }
    }

    private var filterButton: some View {
      Button {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
          isFilterSheetPresented.toggle()
        }
      } label: {
        Label {
          Text(filterLabelText)
        } icon: {
          Image(systemName: filterIconName)
        }
        .symbolRenderingMode(.hierarchical)
      }
      .help("Filter logs by category and level")
      .keyboardShortcut("f", modifiers: .command)
    }

    private var exportButton: some View {
      Button {
        isExportSheetPresented = true
      } label: {
        Label("Export", systemImage: "square.and.arrow.up")
          .symbolRenderingMode(.hierarchical)
      }
      .disabled(model.logs.isEmpty)
      .help("Export logs")
      .keyboardShortcut("e", modifiers: .command)
    }

    private var sortOrderButton: some View {
      Button {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
          sortOrder = sortOrder == .ascending ? .descending : .ascending
        }
      } label: {
        Label(sortOrder.label, systemImage: sortOrder.systemImage)
          .symbolRenderingMode(.hierarchical)
      }
      .help(sortOrder == .ascending ? "Sort newest first" : "Sort oldest first")
    }

    private var rangeMenu: some View {
      Menu {
        Picker("Range", selection: $window) {
          ForEach(LogWindow.allCases) { option in
            Text(option.description).tag(option)
          }
        }
      } label: {
        Label("Range", systemImage: "clock")
      }
      .help("Set the initial log range")
    }

    private var loadOlderButton: some View {
      Button {
        Task {
          await model.loadOlder(filter: filters.filter, window: window)
        }
      } label: {
        Label("Load Older", systemImage: "clock.arrow.circlepath")
      }
      .disabled(isLoading || model.isLoadingOlder || !model.canLoadOlder(window: window))
      .help("Load older logs")
    }

    private var filterIconName: String {
      filters.isActive
        ? "line.3.horizontal.decrease.circle.fill"
        : "line.3.horizontal.decrease.circle"
    }

    private var filterLabelText: String {
      if filters.isActive {
        return "Filter (\(filters.activeCount))"
      }
      return "Filter"
    }

    private func errorOverlay(error: any Error) -> some View {
      VStack(spacing: 16) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 48))
          .foregroundStyle(.orange)
          .symbolEffect(
            .bounce,
            value: model.error?.localizedDescription
          )

        Text("Error loading logs")
          .font(.title2)
          .fontWeight(.bold)

        Button {
          withAnimation {
            model.error = nil
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

    private var loadingOverlay: some View {
      VStack(spacing: 16) {
        ProgressView()
          .scaleEffect(1.5)
          .padding(.bottom, 8)

        Text("Loading logs…")
          .font(.headline)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.ultraThinMaterial)
      .transition(.opacity)
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
          Text(
            selectedOptions.isEmpty ? "None" : "\(selectedOptions.count) selected"
          )
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

// swift-format-ignore: AvoidRetroactiveConformances
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
      return .cyan
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

  fileprivate var exportDescription: String {
    switch self {
    case .log: return "Log File (.log)"
    case .json: return "JSON (.json)"
    case .plainText: return "Plain Text (.txt)"
    case .commaSeparatedText: return "CSV (.csv)"
    default: return description
    }
  }

  fileprivate var exportIcon: String {
    switch self {
    case .log: return "doc.text"
    case .json: return "curlybraces"
    case .plainText: return "doc.plaintext"
    case .commaSeparatedText: return "tablecells"
    default: return "doc"
    }
  }
}

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
}

extension SystemLog.LogModel {
  fileprivate enum LoggerError: AudioError, LocalizedError {
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

    var description: String {
      errorDescription ?? String(describing: self)
    }
  }
}

extension SystemLog.LogModel {

  fileprivate func subscribe(filter: OSLogStream.Filter, window: SystemLog.LogWindow) async {
    // If re-entering with the same parameters and we already have logs,
    // skip the full refetch and just resume polling for new entries.
    let canResume = activeFilter == filter && activeWindow == window && !logs.isEmpty
    let resumeDate = loadedEndDate

    if !canResume {
      logs = []
      error = nil
      self.exportState = .processing
      isLoadingOlder = false
      activeFilter = filter
      activeWindow = window
    }

    subscriptionID = UUID()
    let token = subscriptionID

    do {
      if !canResume {
        let endDate = Date.now
        let processStart = processStartDate
        let startDate: Date =
          if let duration = window.duration {
            max(processStart, endDate.addingTimeInterval(-duration))
          } else {
            processStart
          }
        loadedStartDate = startDate
        loadedEndDate = endDate

        var receivedInitial = false
        for try await batch in OSLogStream.fetchRangeBatches(
          from: startDate,
          to: endDate,
          inclusiveEnd: true,
          batchSize: 200,
          filter: filter
        ) {
          try Task.checkCancellation()
          guard subscriptionID == token else { return }
          guard !batch.isEmpty else { continue }
          receivedInitial = true
          logs.append(contentsOf: batch)
          if let last = batch.last {
            loadedEndDate = max(loadedEndDate ?? last.date, last.date)
          }
          if exportState == .processing {
            exportState = .ready
          }
        }

        if !receivedInitial {
          exportState = .ready
        }
      }

      let pollFrom = (canResume ? resumeDate : loadedEndDate) ?? Date.now
      try await OSLogStream.withCallback(
        batchSize: 200,
        from: pollFrom,
        pollInterval: .seconds(2),
        filter: filter
      ) { entries in
        guard self.subscriptionID == token else { return }
        guard !entries.isEmpty else { return }
        self.logs.append(contentsOf: entries)
        if let last = entries.last {
          self.loadedEndDate = max(self.loadedEndDate ?? last.date, last.date)
        }
      }
    } catch {
      if let streamError = error as? OSLogStream.StreamError, case .cancelled = streamError {
        return
      }
      self.error = error
      self.exportState = .ready
    }
  }

  fileprivate func loadOlder(filter: OSLogStream.Filter, window: SystemLog.LogWindow) async {
    guard !isLoadingOlder else { return }
    guard let duration = window.duration else { return }
    guard let loadedStartDate else { return }
    let processStart = processStartDate
    guard loadedStartDate > processStart else { return }
    let targetStart = max(processStart, loadedStartDate.addingTimeInterval(-duration))
    let targetEnd = loadedStartDate
    guard targetStart < targetEnd else { return }

    let token = subscriptionID
    isLoadingOlder = true
    defer { isLoadingOlder = false }

    do {
      var insertionIndex = 0
      for try await batch in OSLogStream.fetchRangeBatches(
        from: targetStart,
        to: targetEnd,
        inclusiveEnd: false,
        batchSize: 200,
        filter: filter
      ) {
        try Task.checkCancellation()
        guard subscriptionID == token else { return }
        guard !batch.isEmpty else { continue }
        logs.insert(contentsOf: batch, at: insertionIndex)
        insertionIndex += batch.count
        updateKnownSets(with: batch)
      }
      self.loadedStartDate = targetStart
    } catch {
      if let streamError = error as? OSLogStream.StreamError, case .cancelled = streamError {
        return
      }
      logger.error("Load older logs failed: \(error, privacy: .public)")
    }
  }

  fileprivate func canLoadOlder(window: SystemLog.LogWindow) -> Bool {
    guard window.duration != nil else { return false }
    guard let loadedStartDate else { return false }
    return loadedStartDate > processStartDate
  }

  private var processStartDate: Date {
    Date() - ProcessInfo.processInfo.systemUptime
  }

  nonisolated fileprivate static func exportLogs(
    _ logs: [OSLogStream.LogEntry],
    as format: UTType,
    csvDelimiter: SystemLog.Delimiter = .comma
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
      return logs.map { $0.formatted() }.joined(separator: "\n")
    default:
      return ""
    }
  }
  fileprivate func writeLogs(as format: UTType, to url: URL) async throws(LoggerError) {
    guard Self.allowedTypes.contains(format) else {
      logger.error("Unsupported export format: \(format, privacy: .public)")
      throw LoggerError.unsupportedFormatType
    }
    let logs = self.logs
    let task = Task { @Background [logs] in
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

  nonisolated private static func logEntriesToJSON(logEntries: [OSLogStream.LogEntry]) -> String {
    let jsonEncoder = JSONEncoder()
    jsonEncoder.outputFormatting = .prettyPrinted
    if let jsonData = try? jsonEncoder.encode(logEntries),
      let jsonString = String(data: jsonData, encoding: .utf8)
    {
      return jsonString
    }
    return ""
  }
  nonisolated private static func logEntriesToCSV(
    logEntries: [OSLogStream.LogEntry], delimiter: SystemLog.Delimiter
  ) -> String {
    let headers = ["Date", "Level", "Subsystem", "Category", "Message"]
    let csvHeaders = headers.joined(separator: delimiter.rawValue)

    let csvStrings = logEntries.map { entry in

      return [
        entry.date.ISO8601Format(),
        entry.level.rawValue,
        entry.subsystem ?? "",
        entry.category ?? "",
        entry.composedMessage,
      ]
      .joined(separator: delimiter.rawValue)
    }
    return ([csvHeaders] + csvStrings).joined(separator: "\n")
  }
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

          Button("Export Logs…") {
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

extension OSLogStream.LogEntry.LogLevel {
  var systemLog: SystemLog.Level {
    switch self {
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
    case .undefined:
      .undefined
    }
  }
}
