public import Foundation

// SAFETY: Written once during app startup (single-threaded init) before any concurrent access.
// Read only from the exception handler, which runs synchronously on the crashing thread
// immediately before abort().
nonisolated(unsafe) private var _exceptionLogsDirectoryPath: String?

/// Captures uncaught `NSException` details and writes them to the same daily log file
/// used by ``DiskLogWriter``.
///
/// Install early in app startup, passing the same `baseDirectory` used for ``DiskLogWriter``:
/// ```swift
/// UncaughtExceptionLogger.install(baseDirectory: appSupportDirectory)
/// ```
///
/// Exception details (name, reason, call stack) are written to
/// `<baseDirectory>/logs/YYYY-MM-DD.log` using POSIX I/O for reliability in a pre-abort context.
public enum UncaughtExceptionLogger {

  /// Installs an uncaught Objective-C exception handler that writes exception details to disk.
  ///
  /// - Parameter baseDirectory: The parent directory. A `logs/` subdirectory is used,
  ///   matching ``DiskLogWriter``'s file layout.
  public static func install(baseDirectory: URL) {
    let logsDir = baseDirectory.appendingPathComponent("logs", isDirectory: true)
    // Ensure the directory exists (idempotent if DiskLogWriter already created it).
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    unsafe _exceptionLogsDirectoryPath = logsDir.path
    NSSetUncaughtExceptionHandler(_handleUncaughtException)
  }
}

// MARK: - C-compatible handler

/// Top-level function compatible with `@convention(c)` — no context captures.
private func _handleUncaughtException(_ exception: NSException) {
  guard let dirPath = unsafe _exceptionLogsDirectoryPath else { return }

  // Format timestamp using C APIs — avoids Foundation allocations in a pre-abort context.
  var now = time(nil)
  var localTime = unsafe tm()
  _ = unsafe localtime_r(&now, &localTime)

  var dateBuf = [CChar](repeating: 0, count: 32)
  _ = unsafe strftime(&dateBuf, dateBuf.count, "%Y-%m-%d", &localTime)
  let dateStr = String(
    decoding: dateBuf.prefix(while: { $0 != 0 }).lazy.map(UInt8.init(bitPattern:)),
    as: UTF8.self
  )

  var timestampBuf = [CChar](repeating: 0, count: 64)
  _ = unsafe strftime(&timestampBuf, timestampBuf.count, "%Y-%m-%d %H:%M:%S", &localTime)
  let timestamp = String(
    decoding: timestampBuf.prefix(while: { $0 != 0 }).lazy.map(UInt8.init(bitPattern:)),
    as: UTF8.self
  )

  let name = exception.name.rawValue
  let reason = exception.reason ?? "(no reason)"
  let userInfo = exception.userInfo.map { "\($0)" } ?? "(none)"
  let symbols = exception.callStackSymbols

  var entry = "\(timestamp) [EXCEPTION] \(name): \(reason)\n"
  entry += "  UserInfo: \(userInfo)\n"
  for symbol in symbols {
    entry += "  \(symbol)\n"
  }
  entry += "\n"

  // Write to today's log file using POSIX I/O (safest in a pre-abort context).
  let filePath = dirPath + "/" + dateStr + ".log"
  let data = Array(entry.utf8)
  unsafe filePath.withCString { pathPtr in
    let fd = unsafe open(pathPtr, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    unsafe data.withUnsafeBufferPointer { buf in
      if let base = buf.baseAddress {
        _ = unsafe write(fd, base, buf.count)
      }
    }
    close(fd)
  }
}
