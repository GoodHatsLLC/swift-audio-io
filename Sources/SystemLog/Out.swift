import Foundation
import os
import Tools

public enum Standard {
  /// A ``TextOutputStream`` to `stderr`
  ///
  /// ```swift
  /// var stderr = Standard.Error()
  /// print("Hello", to: &stderr)
  /// ```
  ///
  /// - Important:
  /// Writes lock to prevent interleaved output from multiple writers.
  public struct Error: TextOutputStream, Sendable {
    private static let handle = OSAllocatedUnfairLock(initialState: FileHandle.standardError)
    public func write(_ string: String) {
      Self.handle.withLock {
        $0.write(Data(string.utf8))
      }
    }
  }
  /// A ``TextOutputStream`` to `stdout`
  ///
  /// ```swift
  /// var stdout = Standard.Out()
  /// print("Hello", to: &stdout)
  /// ```
  ///
  /// - Important:
  /// Writes lock to prevent interleaved output from multiple writers.
  public struct Out: TextOutputStream, Sendable {
    private static let handle = OSAllocatedUnfairLock(initialState: FileHandle.standardOutput)
    public func write(_ string: String) {
      Self.handle.withLock {
        $0.write(Data(string.utf8))
      }
    }
  }
}

public final class File: TextOutputStream, Sendable {
  public enum FileError: TypedThrowsError {
    case openForUpdatingFailed(url: URL, error: ErrorContext)

    public var description: String {
      switch self {
      case .openForUpdatingFailed(let url, let error):
        "Failed to open file for updating (\(url.lastPathComponent)): \(error)"
      }
    }
  }

  public init(url: URL) throws(FileError) {
    do {
      self.handle = try FileHandle(forUpdating: url)
    } catch {
      throw .openForUpdatingFailed(url: url, error: ErrorContext(error))
    }
  }
  let handle: FileHandle
  public func write(_ string: String) {
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(string.utf8))
    } catch {}
  }
  deinit {
    try? handle.close()
  }
}
