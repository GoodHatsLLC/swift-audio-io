import AsyncAlgorithms
import Dispatch
public import Foundation
public import OSLog
public import SwiftUI
public import Tools

public struct OSLogStream: AsyncSequence {
  public enum StreamError: AudioError, LocalizedError {
    case cancelled
    case file(File.FileError)
    case logStoreCreationFailed(scope: String, error: ErrorContext)
    case queryFailed(error: ErrorContext)

    public var description: String {
      switch self {
      case .cancelled:
        "OSLogStream operation cancelled"
      case .file(let error):
        "OSLogStream file output failed: \(error)"
      case .logStoreCreationFailed(let scope, let error):
        "Failed to create OSLogStore (scope: \(scope)): \(error)"
      case .queryFailed(let error):
        "OSLogStore query failed: \(error)"
      }
    }

    public var errorDescription: String? {
      description
    }
  }

  /// Fetches log entries for a fixed time range.
  ///
  /// This is intended for fast "initial load" style queries. It does not poll.
  @concurrent
  public static nonisolated func fetchRange(
    from startDate: Date,
    to endDate: Date,
    inclusiveEnd: Bool = false,
    scope: OSLogStore.Scope = .currentProcessIdentifier,
    filter: Filter = .any
  ) async throws(StreamError) -> [LogEntry] {
    guard startDate <= endDate else { return [] }
    guard !Task.isCancelled else {
      throw .cancelled
    }

    let result = await withCheckedContinuation {
      (continuation: CheckedContinuation<Result<[LogEntry], StreamError>, Never>) in
      DispatchQueue.global(qos: .userInitiated).async { [filter] in
        do {
          let logStore: OSLogStore
          do {
            logStore = try OSLogStore(scope: scope)
          } catch {
            continuation.resume(
              returning: .failure(
                .logStoreCreationFailed(
                  scope: String(describing: scope),
                  error: ErrorContext(error)
                )
              )
            )
            return
          }

          let datePredicate: NSPredicate =
            if inclusiveEnd {
              NSPredicate(
                format: "date >= %@ AND date <= %@", startDate as NSDate, endDate as NSDate)
            } else {
              NSPredicate(
                format: "date >= %@ AND date < %@", startDate as NSDate, endDate as NSDate)
            }

          let compoundPredicate = NSCompoundPredicate(
            andPredicateWithSubpredicates: [
              datePredicate,
              filter.predicate,
            ]
          )

          let itemSequence = try logStore.getEntries(matching: compoundPredicate)
          var items: [LogEntry] = []
          for item in itemSequence {
            let entry = LogEntry(log: item)
            guard filter.matches(entry) else { continue }
            items.append(entry)
          }
          continuation.resume(returning: .success(items))
        } catch {
          continuation.resume(returning: .failure(.queryFailed(error: ErrorContext(error))))
        }
      }
    }

    guard !Task.isCancelled else {
      throw .cancelled
    }

    switch result {
    case .success(let items):
      return items
    case .failure(let error):
      throw error
    }
  }

  /// Fetches log entries for a fixed time range by splitting it into multiple non-overlapping shards.
  ///
  /// This can significantly reduce "time to first render" when the underlying store query is slow.
  @concurrent
  public static nonisolated func fetchSharded(
    from startDate: Date,
    to endDate: Date,
    shardCount: Int,
    scope: OSLogStore.Scope = .currentProcessIdentifier,
    filter: Filter = .any
  ) async throws(StreamError) -> [LogEntry] {
    guard startDate <= endDate else { return [] }
    let shardCount = Swift.max(1, shardCount)

    let total = endDate.timeIntervalSince(startDate)
    if total <= 0 || shardCount == 1 {
      return try await fetchRange(
        from: startDate,
        to: endDate,
        inclusiveEnd: true,
        scope: scope,
        filter: filter
      )
    }

    let shardDuration = total / Double(shardCount)

    do {
      return try await withThrowingTaskGroup(of: (Int, [LogEntry]).self) { group in
        for shardIndex in 0..<shardCount {
          let shardStart = startDate.addingTimeInterval(Double(shardIndex) * shardDuration)
          let shardEnd: Date =
            if shardIndex == shardCount - 1 {
              endDate
            } else {
              startDate.addingTimeInterval(Double(shardIndex + 1) * shardDuration)
            }
          let inclusiveEnd = shardIndex == shardCount - 1

          group.addTask {
            guard !Task.isCancelled else {
              throw StreamError.cancelled
            }
            let entries = try await fetchRange(
              from: shardStart,
              to: shardEnd,
              inclusiveEnd: inclusiveEnd,
              scope: scope,
              filter: filter
            )
            return (shardIndex, entries)
          }
        }

        var buckets = Array(repeating: [LogEntry](), count: shardCount)
        for try await (index, entries) in group {
          buckets[index] = entries
        }
        return buckets.flatMap { $0 }
      }
    } catch let error as StreamError {
      throw error
    } catch {
      preconditionFailure("Unexpected error type: \(error)")
    }
  }

  /// Streams log entries for a fixed time range in batches.
  ///
  /// This is intended for fast "time to first render" by yielding results as they are read.
  public static nonisolated func fetchRangeBatches(
    from startDate: Date,
    to endDate: Date,
    inclusiveEnd: Bool = false,
    batchSize: Int = 200,
    scope: OSLogStore.Scope = .currentProcessIdentifier,
    filter: Filter = .any
  ) -> AsyncThrowingStream<[LogEntry], any Error> {
    AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .userInitiated) {
        do {
          guard startDate <= endDate else {
            continuation.finish()
            return
          }
          let batchSize = Swift.max(1, batchSize)

          let logStore: OSLogStore
          do {
            logStore = try OSLogStore(scope: scope)
          } catch {
            continuation.finish(
              throwing: StreamError.logStoreCreationFailed(
                scope: String(describing: scope),
                error: ErrorContext(error)
              )
            )
            return
          }

          let datePredicate: NSPredicate =
            if inclusiveEnd {
              NSPredicate(
                format: "date >= %@ AND date <= %@", startDate as NSDate, endDate as NSDate)
            } else {
              NSPredicate(
                format: "date >= %@ AND date < %@", startDate as NSDate, endDate as NSDate)
            }

          let compoundPredicate = NSCompoundPredicate(
            andPredicateWithSubpredicates: [
              datePredicate,
              filter.predicate,
            ]
          )

          let itemSequence = try logStore.getEntries(matching: compoundPredicate)
          var batch: [LogEntry] = []
          batch.reserveCapacity(batchSize)

          for item in itemSequence {
            if Task.isCancelled {
              throw StreamError.cancelled
            }
            let entry = LogEntry(log: item)
            guard filter.matches(entry) else { continue }
            batch.append(entry)
            if batch.count >= batchSize {
              continuation.yield(batch)
              batch.removeAll(keepingCapacity: true)
            }
          }

          if !batch.isEmpty {
            continuation.yield(batch)
          }

          continuation.finish()
        } catch let error as StreamError {
          continuation.finish(throwing: error)
        } catch {
          if Task.isCancelled {
            continuation.finish(throwing: StreamError.cancelled)
            return
          }
          continuation.finish(throwing: StreamError.queryFailed(error: ErrorContext(error)))
        }
      }

      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  public static nonisolated func withCallback(
    batchSize: Int = 100,
    from date: Date? = nil,
    pollInterval: Duration = .seconds(5),
    filter: Filter = .any,
    _ callback: @escaping @MainActor ([LogEntry]) async -> Void
  ) async throws(StreamError) {
    // Apply backpressure to the iteration via a channel
    let channel = AsyncChannel<[LogEntry]>()
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask(
          executorPreference: Background.executor,
          priority: .background
        ) {
          do {
            for try await batch in OSLogStream(
              batchSize: batchSize,
              from: date,
              filter: filter
            ) {
              await channel.send(batch)
            }
          } catch let error as StreamError {
            throw error
          } catch {
            if Task.isCancelled {
              throw StreamError.cancelled
            }
            throw StreamError.queryFailed(error: ErrorContext(error))
          }
        }
        group.addTask {
          do {
            // consume in a loop
            for await batch in channel {
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
                  do {
                    try await Task.sleep(for: pollInterval)
                  } catch {
                    throw StreamError.cancelled
                  }
                }
              }
            }
          } catch {
            if Task.isCancelled {
              throw StreamError.cancelled
            }
            throw StreamError.queryFailed(error: ErrorContext(error))
          }
        }
        try await group.waitForAll()
      }
    } catch let error as StreamError {
      throw error
    } catch {
      if Task.isCancelled {
        throw .cancelled
      }
      preconditionFailure("Unexpected error type: \(error)")
    }
  }

  @concurrent
  public static nonisolated func to(
    file url: URL,
    batchSize: Int = 100,
    pollInterval interval: Duration = .seconds(5),
    filter: Filter = .any,
    from date: Date? = nil
  ) async throws(StreamError) {
    do {
      var file = try File(url: url)
      try await to(
        textStream: &file,
        batchSize: batchSize,
        pollInterval: interval,
        filter: filter
      )
    } catch let error as File.FileError {
      throw .file(error)
    } catch let error as StreamError {
      throw error
    } catch {
      throw .queryFailed(error: ErrorContext(error))
    }
  }

  @concurrent
  public static nonisolated func toStandardOut(
    batchSize: Int = 100,
    pollInterval interval: Duration = .seconds(5),
    filter: Filter = .any,
    from date: Date? = nil
  ) async throws(StreamError) {
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
  ) async throws(StreamError) {
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
  ) async throws(StreamError) {
    for try await chunk in OSLogStream(
      batchSize: batchSize,
      from: date,
      filter: filter
    ) {
      if chunk.count > 0 {
        let str = chunk.reduce(into: "") { acc, entry in
          acc.append(entry.formatted() + "\n")
        }
        str.write(to: &textStream)
      }
      if chunk.count < batchSize {
        do {
          try await Task.sleep(for: pollInterval)
        } catch {
          throw .cancelled
        }
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
    let logStore: Result<OSLogStore, StreamError> = {
      do {
        return .success(try OSLogStore(scope: .currentProcessIdentifier))
      } catch {
        return .failure(
          .logStoreCreationFailed(
            scope: "currentProcessIdentifier",
            error: ErrorContext(error)
          )
        )
      }
    }()

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

    private mutating func get() throws(StreamError) -> [LogEntry] {
      let logStore: OSLogStore
      switch self.logStore {
      case .success(let store):
        logStore = store
      case .failure(let error):
        throw error
      }
      let datePredicate = NSPredicate(
        format: "date > %@",
        queryStartDate as NSDate
      )

      let compoundPredicate = NSCompoundPredicate(
        andPredicateWithSubpredicates: [
          datePredicate,
          predicate(),
        ]
      )

      let itemSequence: AnySequence<OSLogEntry>
      do {
        itemSequence = try logStore.getEntries(matching: compoundPredicate)
      } catch {
        throw .queryFailed(error: ErrorContext(error))
      }

      var items: [LogEntry] = []
      // the maxDate serves as the data cursor
      var maxDate: Date? = nil
      // pull from the underlying iterator one at a time.
      let iterator = itemSequence.makeIterator()
      while let item = iterator.next() {
        // update the cursor
        maxDate = Swift.max(
          maxDate ?? Date.distantPast,
          item.date
        )
        let entry = LogEntry(log: item)
        guard filter.matches(entry) else { continue }
        items.append(entry)
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
    ) async throws(StreamError) -> [LogEntry]? {
      try get()
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
      case .levelFloor:
        // OSLogStore doesn't support filtering by "level" in predicates.
        // Keep predicate permissive and rely on in-memory Filter.matches.
        NSPredicate(value: true)
      case .text(let text):
        NSPredicate(
          format: "composedMessage CONTAINS[c] %@",
          text
        )
      case .level:
        // OSLogStore doesn't support filtering by "level" in predicates.
        // Keep predicate permissive and rely on in-memory Filter.matches.
        NSPredicate(value: true)
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
          format: "date < %@",
          date as NSDate
        )
      case .after(let date):
        NSPredicate(
          format: "date >= %@",
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

    func matches(_ entry: LogEntry) -> Bool {
      switch self {
      case .any:
        return true
      case .text(let text):
        guard !text.isEmpty else { return true }
        return entry.composedMessage.range(
          of: text,
          options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
      case .subsystem(let subsystem):
        return entry.subsystem == subsystem
      case .category(let category):
        return entry.category == category
      case .levelFloor(let minLevel):
        guard entry.type == .log else { return true }
        guard let entry = entry.level.nativeIntValue,
          let minLevel = minLevel.nativeIntValue
        else {
          return true
        }
        return entry >= minLevel
      case .level(let level):
        guard entry.type == .log else { return true }
        return entry.level == level
      case .before(let date):
        return entry.date < date
      case .after(let date):
        return entry.date >= date
      case .and(let filters):
        return filters.allSatisfy { $0.matches(entry) }
      case .or(let filters):
        return filters.contains { $0.matches(entry) }
      }
    }
  }

  public struct LogEntry: Identifiable, Hashable, Sendable, Codable {
    public init(
      type: EntryType,
      level: LogLevel,
      activityIdentifier: UInt64? = nil,
      category: String? = nil,
      composedMessage: String,
      date: Date,
      parentActivityIdentifier: UInt64? = nil,
      process: String? = nil,
      processIdentifier: Int32? = nil,
      sender: String? = nil,
      signpostIdentifier: UInt64? = nil,
      signpostName: String? = nil,
      signpostType: SignpostType? = nil,
      storeCategory: StoreCategory,
      subsystem: String? = nil,
      threadIdentifier: UInt64? = nil
    ) {
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
      self =
        switch log {
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
        if let value = EntryType(rawValue: str) {
          self = value
        } else {
          throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Unknown EntryType: \(str)")
        }
      }
      public func encode(to encoder: any Encoder) throws {
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
        if let value = SignpostType(rawValue: str) {
          self = value
        } else {
          throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Unknown SignpostType: \(str)")
        }
      }
      public func encode(to encoder: any Encoder) throws {
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
        self =
          switch level {
          case .debug: .debug
          case .info: .info
          case .notice: .notice
          case .error: .error
          case .fault: .fault
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
        default: return nil
        }
      }
      public var nativeIntValue: Int? {
        switch self {
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
        }
      }
      var sfSymbol: String {
        switch self {
        case .undefined:
          return "questionmark.app.dashed"
        case .debug:
          return "stethoscope"
        case .info:
          return "info.circle.fill"
        case .notice:
          return "bell.fill"
        case .error:
          return "exclamationmark.circle.fill"
        case .fault:
          return "exclamationmark.triangle.fill"
        }
      }
      static var range: ClosedRange<Int> { 0...5 }
      public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        if let value = LogLevel(rawValue: str) {
          self = value
        } else {
          throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Unknown LogLevel: \(str)")
        }
      }
      public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
      }
      case debug
      case info
      case notice
      case error
      case fault
      case undefined
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
        self =
          switch category {
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
        if let value = StoreCategory(rawValue: str) {
          self = value
        } else {
          throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Unknown StoreCategory: \(str)")
        }
      }
      public func encode(to encoder: any Encoder) throws {
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
