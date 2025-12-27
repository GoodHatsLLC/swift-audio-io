import OSLog
import SwiftUI
import Foundation
import AsyncAlgorithms
import OSLog
import Foundation
import AsyncAlgorithms

public struct OSLogStream: AsyncSequence {

  public static nonisolated func withCallback(
    batchSize: Int = 100,
    from date: Date? = nil,
    pollInterval: Duration = .seconds(5),
    filter: Filter = .any,
    _ callback: @escaping @MainActor ([LogEntry]) async -> Void
  ) async throws {
    // Apply backpressure to the iteration via a channel
    let channel = AsyncChannel<[LogEntry]>()
    try await withThrowingTaskGroup { group in
      group.addTask(
        executorPreference: Background.executor,
        priority: .background
      ) {
        for try await batch in OSLogStream(
          batchSize: batchSize,
          from: date,
          filter: filter
        ) {
            // we await consumption
            await channel.send(batch)
        }
      }
      group.addTask {
        // consume in a loop
          for try await batch in channel {
            let callOut = Date.now
            // only notify the consumer if we have data
            if batch.count > 0 {
              // await the callback's execution before continuing
              await callback(batch)
            }
            // if we did not hit the batch size, sleep
            // before allowing polling again.
            if batch.count < batchSize {
              let callTime = Date.now.timeIntervalSince(callOut)
              let sleepTime = Swift.max(0.0, pollInterval / .seconds(1) - callTime)
              if sleepTime > 0.0 {
                try await Task.sleep(for: pollInterval)
              }
            }
          }
      }
      try await group.waitForAll()
    }
  }
  
  
  @concurrent
  public static nonisolated func to(
    file url: URL,
    batchSize: Int = 100,
    pollInterval interval: Duration = .seconds(5),
    filter: Filter = .any,
    from date: Date? = nil
  ) async throws {
    var file = try File(url: url)
    try await to(
      textStream: &file,
      batchSize: batchSize,
      pollInterval: interval,
      filter: filter
    )
  }
  
  @concurrent
  public static nonisolated func toStandardOut(
    batchSize: Int = 100,
    pollInterval interval: Duration = .seconds(5),
    filter: Filter = .any,
    from date: Date? = nil
  ) async throws {
    var stdout = Standard.Out()
    try await to(
      textStream: &stdout,
      pollInterval: interval,
      filter: filter
    )
  }
  
  @concurrent
  public static nonisolated func toStandardError(
    batchSize: Int = 100,
    pollInterval interval: Duration = .seconds(5),
    filter: Filter = .any,
    from date: Date? = nil
  ) async throws {
    var stdout = Standard.Error()
    try await to(
      textStream: &stdout,
      pollInterval: interval,
      filter: filter
    )
  }
  
  public static nonisolated func to(
    textStream: inout some TextOutputStream,
    batchSize: Int = 100,
    pollInterval: Duration = .seconds(5),
    filter: Filter,
    from date: Date? = nil
  ) async throws {
    for try await chunk in OSLogStream(
      batchSize: batchSize,
      from: date,
      filter: filter
    ) {
      if chunk.count > 0 {
        let str = chunk.reduce(into: "") { acc, entry in
          acc.append(entry.formatted()+"\n")
        }
        str.write(to: &textStream)
      }
      if chunk.count < batchSize {
        try await Task.sleep(for: pollInterval)
      }
    }
  }
  
  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(
      date: date,
      filter: filter,
      batchSize: batchSize
    )
  }
  
  public init(
    batchSize: Int? = nil,
    from: Date? = nil,
    filter: Filter = .any
  ) {
    self.batchSize = batchSize
    self.date = from
    self.filter = filter
  }
  
  let batchSize: Int?
  let date: Date?
  let filter: Filter
  
  public struct AsyncIterator: AsyncIteratorProtocol {
    var date: Date?
    let filter: Filter
    let batchSize: Int?
    var _predicate: NSPredicate?
    mutating func predicate() -> NSPredicate {
      if let _predicate {
        return _predicate
      } else {
        let predicate = filter.predicate
        _predicate = predicate
        return predicate
      }
    }
    let logStore = Result {
      try OSLogStore(scope: .currentProcessIdentifier)
    }
    
    private var processStartDate: Date {
      (Date() - ProcessInfo.processInfo.systemUptime)
    }
    private var queryStartDate: Date {
      get {
        date ?? processStartDate
      }
      set {
        date = newValue
      }
    }
    
    private mutating func get() throws -> [OSLogEntry] {
      let logStore = try self.logStore.get()
      let datePredicate = NSPredicate(
        format: "date > %@",
        queryStartDate as NSDate
      )

      let compoundPredicate = NSCompoundPredicate(
        andPredicateWithSubpredicates: [
          datePredicate,
          predicate()
        ]
      )
      
      let itemSequence: AnySequence<OSLogEntry> = try logStore
        .getEntries(matching: compoundPredicate)
        
      var items: [OSLogEntry] = []
      // the maxDate serves as the data cursor
      var maxDate: Date? = nil
      // pull from the underlying iterator one at a time.
      while let item = itemSequence.makeIterator().next() {
        // store the item
        items.append(item)
        // update the cursor
        maxDate = Swift.max(
          maxDate ?? Date.distantPast,
          item.date
        )
        // if we reach the batch size, end pulling from the
        // iterator.
        if let batchSize, items.count >= batchSize {
          break
        }
      }
      queryStartDate = maxDate ?? queryStartDate
      return items
    }
    
    public mutating func next(
      isolation actor: isolated (any Actor)?
    ) async throws(any Error) -> [LogEntry]? {
      try get().map { ent in
          LogEntry(log: ent)
      }
    }
  }
  
}


extension OSLogStream {
  
  public indirect enum Filter: Sendable, Hashable, Identifiable {
    case any
    case text(String)
    case subsystem(String)
    case category(String)
    case levelFloor(OSLogStream.LogEntry.LogLevel)
    case level(OSLogStream.LogEntry.LogLevel)
    case before(Date)
    case after(Date)
    case and([Filter])
    case or([Filter])
    
    public var id: Self {
      self
    }
    
    public var description: String {
      switch self {
      case .any: "*"
      case .text(let text):
        "text=\(text)"
      case .levelFloor(let level):
        "level>=\(level)"
      case .level(let level):
        "level=\(level)"
      case .category(let category):
        "category=\(category)"
      case .subsystem(let subsystem):
        "subsystem=\(subsystem)"
      case .before(let date):
        "date<\(date.ISO8601Format())"
      case .after(let date):
        "date>=\(date.ISO8601Format())"
      case .or(let filters):
        "(\(filters.map(\.description).joined(separator: " OR ")))"
      case .and(let filters):
        "(\(filters.map(\.description).joined(separator: " AND ")))"
      }
    }
    
    public var predicate: NSPredicate {
      switch self {
      case .any: NSPredicate.init(value: true)
      case .levelFloor(let minLevel):
        NSPredicate(
          format: "level >= %d",
          minLevel.nativeIntValue
        )
      case .text(let text):
        NSPredicate(
          format: "message CONTAINS[c] %@",
          text
        )
      case .level(let floor):
        NSPredicate(
          format: "level == %d",
          floor.nativeIntValue
        )
      case .category(let category):
        NSPredicate(
          format: "category == %@",
          category
        )
      case .subsystem(let subsystem):
        NSPredicate(
          format: "subsystem == %@",
          subsystem
        )
      case .before(let date):
        NSPredicate(
          format: "timestamp < %@",
          date as NSDate
        )
      case .after(let date):
        NSPredicate(
          format: "timestamp >= %@",
          date as NSDate
        )
      case .and(let filters):
        NSCompoundPredicate(
          andPredicateWithSubpredicates: filters.compactMap(\.predicate)
        )
      case .or(let filters):
        NSCompoundPredicate(
          orPredicateWithSubpredicates: filters.compactMap(\.predicate)
        )
      }
    }
  }
  
  public struct LogEntry: Identifiable, Hashable, Sendable, Codable {
    public init(type: EntryType, level: LogLevel, activityIdentifier: UInt64? = nil, category: String? = nil, composedMessage: String, date: Date, parentActivityIdentifier: UInt64? = nil, process: String? = nil, processIdentifier: Int32? = nil, sender: String? = nil, signpostIdentifier: UInt64? = nil, signpostName: String? = nil, signpostType: SignpostType? = nil, storeCategory: StoreCategory, subsystem: String? = nil, threadIdentifier: UInt64? = nil) {
      self.type = type
      self.level = level
      self.activityIdentifier = activityIdentifier
      self.category = category
      self.composedMessage = composedMessage
      self.date = date
      self.parentActivityIdentifier = parentActivityIdentifier
      self.process = process
      self.processIdentifier = processIdentifier
      self.sender = sender
      self.signpostIdentifier = signpostIdentifier
      self.signpostName = signpostName
      self.signpostType = signpostType
      self.storeCategory = storeCategory
      self.subsystem = subsystem
      self.threadIdentifier = threadIdentifier
    }
    public init(log: OSLogEntry) {
      self = switch log {
      case let log as OSLogEntryLog:
        LogEntry(
          type: .log,
          level: .init(level: log.level),
          activityIdentifier: log.activityIdentifier,
          category: log.category,
          composedMessage: log.composedMessage,
          date: log.date,
          parentActivityIdentifier: nil,
          process: log.process,
          processIdentifier: log.processIdentifier,
          sender: log.sender,
          signpostIdentifier: nil,
          signpostName: nil,
          signpostType: nil,
          storeCategory: .init(
            category: log.storeCategory
          ),
          subsystem: log.subsystem,
          threadIdentifier: log.threadIdentifier
        )
      case let log as OSLogEntrySignpost:
        LogEntry(
          type: .signpost,
          level: .undefined,
          activityIdentifier: log.activityIdentifier,
          category: log.category,
          composedMessage: log.composedMessage,
          date: log.date,
          parentActivityIdentifier: nil,
          process: log.process,
          processIdentifier: log.processIdentifier,
          sender: log.sender,
          signpostIdentifier: log.signpostIdentifier,
          signpostName: log.signpostName,
          signpostType: .init(type: log.signpostType),
          storeCategory: .init(
            category: log.storeCategory
          ),
          subsystem: log.subsystem,
          threadIdentifier: log.threadIdentifier
        )
      case let log as OSLogEntryActivity:
        LogEntry(
          type: .activity,
          level: .undefined,
          activityIdentifier: log.activityIdentifier,
          category: nil,
          composedMessage: log.composedMessage,
          date: log.date,
          parentActivityIdentifier: log.parentActivityIdentifier,
          process: log.process,
          processIdentifier: log.processIdentifier,
          sender: log.sender,
          signpostIdentifier: nil,
          signpostName: nil,
          storeCategory: .init(
            category: log.storeCategory
          ),
          subsystem: nil,
          threadIdentifier: log.threadIdentifier
        )
      case let log as OSLogEntryBoundary:
        LogEntry(
          type: .boundary,
          level: .undefined,
          activityIdentifier: nil,
          category: nil,
          composedMessage: log.composedMessage,
          date: log.date,
          parentActivityIdentifier: nil,
          process: nil,
          processIdentifier: nil,
          sender: nil,
          signpostIdentifier: nil,
          signpostName: nil,
          signpostType: nil,
          storeCategory: .init(
            category: log.storeCategory
          ),
          subsystem: nil,
          threadIdentifier: nil
        )
      default:
        LogEntry(
          type: .other,
          level: .undefined,
          activityIdentifier: nil,
          category: nil,
          composedMessage: log.composedMessage,
          date: log.date,
          parentActivityIdentifier: nil,
          process: nil,
          processIdentifier: nil,
          sender: nil,
          signpostIdentifier: nil,
          signpostName: nil,
          signpostType: nil,
          storeCategory: .init(
            category: log.storeCategory
          ),
          subsystem: nil,
          threadIdentifier: nil
        )
      }
    }
    public enum EntryType: String, Sendable, Codable {
      case log
      case boundary
      case activity
      case signpost
      case other
      public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        if
          let value = EntryType(rawValue: str) {
          self = value
        } else {
          throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown EntryType: \(str)")
        }
      }
      public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
      }
    }
    public enum SignpostType: String, Sendable, Codable {
      case undefined
      case intervalBegin
      case intervalEnd
      case event
      case unknown
      public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        if
          let value = SignpostType(rawValue: str) {
          self = value
        } else {
          throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown SignpostType: \(str)")
        }
      }
      public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
      }
      public init(type: OSLogEntrySignpost.SignpostType) {
        switch type {
        case .undefined: self = .undefined
        case .intervalBegin: self = .intervalBegin
        case .intervalEnd: self = .intervalEnd
        case .event: self = .event
        @unknown default:
          self = .unknown
        }
      }
    }
    public enum LogLevel: String, Sendable, Codable, CaseIterable {
      public init(level: OSLogEntryLog.Level) {
        self = switch level {
        case .debug:  .debug
        case .info:  .info
        case .notice:  .notice
        case .error:  .error
        case .fault:  .fault
        case .undefined: .undefined
        @unknown default: .undefined
        }
      }
      public init?(nativeIntValue: Int) {
        switch nativeIntValue {
          case 0: self = .undefined
          case 1: self = .debug
          case 2: self = .info
          case 3: self = .notice
          case 4: self = .error
          case 5: self = .fault
          default: self = .unknown
        }
      }
      public var nativeIntValue: Int {
        switch self {
        case .unknown: -1
        case .undefined: 0
        case .debug: 1
        case .info: 2
        case .notice: 3
        case .error: 4
        case .fault: 5
        }
      }
      
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
      static var range: ClosedRange<Int> { 0...5 }
      public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        if
          let value = LogLevel(rawValue: str) {
          self = value
        } else {
          throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown LogLevel: \(str)")
        }
      }
      public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
      }
      case debug
      case info
      case notice
      case error
      case fault
      case undefined
       case unknown
    }
    
    public enum StoreCategory: String, Sendable, Codable {
      case undefined
      case metadata
      case shortTerm
      case longTermAuto
      case longTerm1
      case longTerm3
      case longTerm7
      case longTerm14
      case longTerm30
      case unknown
      public init(category: OSLogEntry.StoreCategory) {
        self = switch category {
        case .undefined: .undefined
        case .metadata: .metadata
        case .shortTerm: .shortTerm
        case .longTermAuto: .longTermAuto
        case .longTerm1: .longTerm1
        case .longTerm3: .longTerm3
        case .longTerm7: .longTerm7
        case .longTerm14: .longTerm14
        case .longTerm30: .longTerm30
        @unknown default: .unknown
        }
      }
      public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        if
          let value = StoreCategory(rawValue: str) {
          self = value
        } else {
          throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown StoreCategory: \(str)")
        }
      }
      public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
      }
    }
    public var id: Self { self }
    public let type: EntryType
    public let level: LogLevel
    public var activityIdentifier: UInt64?
    public var category: String?
    public var composedMessage: String
    public var date: Date
    public var parentActivityIdentifier: UInt64?
    public var process: String?
    public var processIdentifier: Int32?
    public var sender: String?
    public var signpostIdentifier: UInt64?
    public var signpostName: String?
    public var signpostType: SignpostType?
    public var storeCategory: StoreCategory
    public var subsystem: String?
    public var threadIdentifier: UInt64?

    /// Formats the log entry as a human-readable plain text string.
    ///
    /// Output format varies by entry type:
    /// - Log: `2024-01-15 10:30:45.123 [ERROR] subsystem/category: message`
    /// - Signpost: `2024-01-15 10:30:45.123 ⏱ [BEGIN] signpostName: message`
    /// - Activity: `2024-01-15 10:30:45.123 ▶ activity message`
    /// - Other: `2024-01-15 10:30:45.123 message`
    public func formatted() -> String {
      let timestamp = Self.dateFormatter.string(from: date)

      switch type {
      case .log:
        let levelTag = "[\(level.rawValue.uppercased())]"
        let source = formatSource(subsystem: subsystem, category: category)
        return "\(timestamp) \(levelTag)\(source): \(composedMessage)"

      case .signpost:
        let signpostTag = signpostType.map { "[\($0.rawValue.uppercased())]" } ?? ""
        let name = signpostName.map { "\($0): " } ?? ""
        return "\(timestamp) ⏱ \(signpostTag) \(name)\(composedMessage)"

      case .activity:
        return "\(timestamp) ▶ \(composedMessage)"

      case .boundary:
        return "\(timestamp) ┃ \(composedMessage)"

      case .other:
        return "\(timestamp) \(composedMessage)"
      }
    }

    private func formatSource(subsystem: String?, category: String?) -> String {
      switch (subsystem, category) {
      case (.some(let sub), .some(let cat)):
        return " \(sub)/\(cat)"
      case (.some(let sub), .none):
        return " \(sub)"
      case (.none, .some(let cat)):
        return " \(cat)"
      case (.none, .none):
        return ""
      }
    }

    private static let dateFormatter: DateFormatter = {
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
      return formatter
    }()
  }
}
