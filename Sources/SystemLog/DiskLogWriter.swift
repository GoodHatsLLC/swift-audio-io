import Foundation

private let log = SystemLog.make()

/// Subscribes to ``OSLogStream`` and writes formatted log entries to daily rotating files on disk.
///
/// Files are written to `<baseDirectory>/logs/YYYY-MM-DD.log`.
/// Log file names use the device's local timezone, so files rotate at local midnight.
/// On each launch, files older than ``retentionDays`` are deleted.
///
/// Usage:
/// ```swift
/// let writer = DiskLogWriter(
///   baseDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
/// )
/// try await writer.run() // long-running — cancel the Task to stop
/// ```
public struct DiskLogWriter: Sendable {

  private let logsDirectory: URL
  private let retentionDays: Int
  private let filter: OSLogStream.Filter
  private let pollInterval: Duration
  private let batchSize: Int

  /// Creates a new disk log writer.
  ///
  /// - Parameters:
  ///   - baseDirectory: The parent directory. A `logs/` subdirectory is created inside it.
  ///   - retentionDays: Log files older than this many days are deleted on startup. Defaults to 30.
  ///   - filter: An ``OSLogStream/Filter`` to restrict which entries are written. Defaults to `.any`.
  ///   - pollInterval: How often to poll for new log entries. Defaults to 5 seconds.
  ///   - batchSize: Number of entries to read per poll cycle. Defaults to 200.
  public init(
    baseDirectory: URL,
    retentionDays: Int = 30,
    filter: OSLogStream.Filter = .any,
    pollInterval: Duration = .seconds(5),
    batchSize: Int = 200
  ) {
    self.logsDirectory = baseDirectory.appendingPathComponent("logs", isDirectory: true)
    self.retentionDays = retentionDays
    self.filter = filter
    self.pollInterval = pollInterval
    self.batchSize = batchSize
  }

  /// Starts the writer. This function runs indefinitely until the enclosing ``Task`` is cancelled.
  ///
  /// On entry it:
  /// 1. Creates the logs directory if needed.
  /// 2. Purges stale log files.
  /// 3. Begins streaming from ``OSLogStream`` and appending to daily files.
  public func run() async throws(OSLogStream.StreamError) {
    do {
      try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    } catch {
      log.error("DiskLogWriter: failed to create logs directory at \(logsDirectory.path, privacy: .public): \(error, privacy: .public)")
      assertionFailure("DiskLogWriter: failed to create logs directory: \(error)")
      return
    }

    purgeStaleFiles()

    var stream = RotatingFileStream(logsDirectory: logsDirectory)
    defer { stream.close() }
    try await OSLogStream.to(
      textStream: &stream,
      batchSize: batchSize,
      pollInterval: pollInterval,
      filter: filter
    )
  }
}

// MARK: - RotatingFileStream

/// A ``TextOutputStream`` that directs writes to a daily log file, rotating automatically at local midnight.
///
/// Writes are expected to be serial — this type is used exclusively via the `inout` parameter of
/// ``OSLogStream/to(textStream:batchSize:pollInterval:filter:from:)`` which writes sequentially
/// from a single `for await` loop.
private struct RotatingFileStream: TextOutputStream {
  let logsDirectory: URL

  private var currentDateString: String = ""
  private var currentHandle: FileHandle?

  init(logsDirectory: URL) {
    self.logsDirectory = logsDirectory
  }

  mutating func write(_ string: String) {
    let today = Self.todayString()
    if today != currentDateString {
      closeHandle()
      currentDateString = today
    }

    guard let handle = obtainHandle(for: today) else { return }
    do {
      try handle.write(contentsOf: Data(string.utf8))
    } catch {
      log.warning("DiskLogWriter: write failed: \(error, privacy: .public)")
      // Close the handle so the next cycle attempts a fresh open.
      closeHandle()
    }
  }

  /// Explicitly closes the current file handle. Called on rotation, write failure, and task cancellation.
  mutating func close() {
    closeHandle()
  }

  private mutating func closeHandle() {
    if let handle = currentHandle {
      try? handle.close()
    }
    currentHandle = nil
  }

  private mutating func obtainHandle(for dateString: String) -> FileHandle? {
    if let currentHandle {
      return currentHandle
    }
    let fileURL = logsDirectory.appendingPathComponent("\(dateString).log")
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }
    do {
      let handle = try FileHandle(forWritingTo: fileURL)
      try handle.seekToEnd()
      currentHandle = handle
      return handle
    } catch {
      log.warning("DiskLogWriter: failed to open log file \(fileURL.lastPathComponent, privacy: .public): \(error, privacy: .public)")
      return nil
    }
  }

  private static func todayString() -> String {
    Self.dateFormatter.string(from: Date())
  }

  /// Date formatter using the device's local timezone. Log files rotate at local midnight.
  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    return f
  }()
}

// MARK: - Purge

extension DiskLogWriter {
  /// Removes `.log` files from the logs directory that are older than ``retentionDays``.
  private func purgeStaleFiles() {
    let fm = FileManager.default
    guard let contents = try? fm.contentsOfDirectory(
      at: logsDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return }

    let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast

    for url in contents where url.pathExtension == "log" {
      guard
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
        let modified = values.contentModificationDate,
        modified < cutoff
      else { continue }
      try? fm.removeItem(at: url)
    }
  }
}
