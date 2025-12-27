import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import AsyncAlgorithms
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
    subsystem: String? = nil,
    category: String = Bundle.main.bundleIdentifier ?? "none.bundle"
  )
    -> SystemLogger
  {
    SystemLogger(
      subsystem: { () -> String in
        subsystem
        ?? ("\(file)"
          .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first?
          .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).last).flatMap(
            String.init)
        ?? "\(file)"
      }(),
      category: category
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
  public static func make(file: StaticString = #file, category: String = Bundle.main.bundleIdentifier ?? "none.bundle", subsystem: String? = nil) -> SystemLogger
  {
    Logger.make(
      file: file,
      subsystem: subsystem,
      category: category
    )
  }
  public struct Viewer: View {
    @State private var model: LogModel = .init()
    public init() {}
    public var body: some View {
        LogListScreen(model: model)
    }
  }

  @Observable
  fileprivate final class LogModel {
    var logs: [OSLogStream.LogEntry] = [] {
      didSet {
        let len = max(0, logs.count - oldValue.count)
        let new = logs.suffix(len)
        knownCategories.formUnion(new.map { $0.category ?? "" })
        knownSubsystems.formUnion(new.map{ $0.subsystem ?? "" })
      }
    }
    var error: (any Error)?
    var knownCategories: Set<String> = []
    var knownSubsystems: Set<String> = []
    let levels = OSLogStream.LogEntry.LogLevel.allCases
  
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
            (categories).isEmpty ? .any : .and((categories).map { .category($0) })
          ]
        )
      }
    }
    
    fileprivate var model: LogModel
    @Binding var filters: Filters
    @Binding var isDisplayed: Bool
    @State var newFilters: Filters = .init()

    var body: some View {
      VStack {
        HStack {
          Rectangle().fill(.clear)
            .overlay {
              VStack {
                Button {
                  newFilters.categories = []
                } label: {
                  Label("Clear", systemImage: "xmark")
                }
                ScrollView([.vertical]) {
                  VStack(alignment: .leading) {
                    ForEach(model.knownCategories.compactMap{
                      $0.isEmpty ? nil : $0
                    }.sorted(), id: \.self) { v in
                      Button {
                        if !newFilters.categories.insert(v).inserted {
                          newFilters.categories.remove(v)
                        }
                      } label: {
                        Label(
                          v.description,
                          systemImage: newFilters.categories.contains(v)
                          ? "checkmark.square"
                          : "square"
                        )
                      }.buttonStyle(.plain)
                    }
                  }
                }
              }
            }
          Rectangle().fill(.clear)
            .overlay {
              VStack {
                Button {
                  newFilters.subsystems = []
                } label: {
                  Label("Clear", systemImage: "xmark")
                }
                ScrollView([.vertical]) {
                  VStack(alignment: .leading) {
                    ForEach(model.knownSubsystems.compactMap{
                      $0.isEmpty ? nil : $0
                    }.sorted(), id: \.self) { v in
                      Button {
                        let insert = newFilters.subsystems.insert(v).inserted
                        if !insert {
                          newFilters.subsystems.remove(v)
                        }
                      } label: {
                        Label(
                          v.description,
                          systemImage: newFilters.subsystems.contains(v)
                          ? "checkmark.square"
                          : "square"
                        )
                      }.buttonStyle(.plain)
                    }
                  }
                }
              }
            }
          Rectangle().fill(.clear)
            .overlay {
              VStack {
                Button {
                  newFilters.minLevel = nil
                } label: {
                  Label("Clear", systemImage: "xmark")
                }
                ScrollView([.vertical]) {
                  VStack(alignment: .leading) {
                    ForEach(OSLogStream.LogEntry.LogLevel.allCases, id: \.self) { v in
                      Button {
                        newFilters.minLevel = v
                      } label: {
                        Label(
                          v.description,
                          systemImage: newFilters.minLevel == v
                          ? "checkmark.square"
                          : "square"
                        )
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2, x: 0, y: 0)
                        .padding(4)
                        .background(v.color)
                        .background(in: Capsule())
                      }.buttonStyle(.plain)
                    }
                  }
                }
              }
            }
        }
        .font(.caption)
        HStack {
          Spacer()
          Button {
            isDisplayed = false
          } label: {
            Text("dismiss")
          }
          Button {
            filters = newFilters
          } label: {
            Text("update")
          }
          .disabled(newFilters == filters)
        }
      }
      .padding()
      .task {
        newFilters = filters
      }
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
    @State private var isFilterSheetPresented: Bool = false
    @State private var filters: FilterSheet.Filters = .init()

    fileprivate init(model: LogModel) {
      self.model = model
    }

    var body: some View {
      List {
        ForEach(model.logs) { log in
          LogCell(for: log)
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
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
        .task(id: filters) {
        await model.subscribe(filter: filters.filter)
      }
      .toolbar {
        ToolbarItemGroup(placement: .automatic) {
            filterButton
        }
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
        Label(
          "Filter",
          systemImage: true
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

  @MainActor
  fileprivate func subscribe(filter: OSLogStream.Filter) async {
    logs = []
    self.exportState = .processing
    do {
      try await OSLogStream.withCallback(
        batchSize: 100,
        filter: filter
      ) { entries in
        self.logs.append(contentsOf: entries)
        if self.exportState == .processing {
          self.exportState = .ready
        }
      }
    } catch {
      self.error = error
    }
  }
  fileprivate static func exportLogs(
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
  @MainActor
  fileprivate func writeLogs(as format: UTType, to url: URL) async throws {
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

  private static func logEntriesToJSON(logEntries: [OSLogStream.LogEntry]) -> String {
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
    case .unknown:
        .unknown
    }
  }
}
