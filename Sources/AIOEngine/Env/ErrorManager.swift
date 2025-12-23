import Observation
import SystemLog

private let log = SystemLog.make()

@Observable
public final class ErrorManager: Sendable {
  public nonisolated init() {}
  @MainActor
  public var errors: [any Error] = []
  
  @MainActor
  public func popError() -> (any Error)? {
    if !errors.isEmpty {
      errors.removeFirst()
    } else {
      nil
    }
  }
  @MainActor
  public func enqueue(_ error: any Error) {
    errors.append(error)
  }

  public var report: Reporter<any Error> {
    .init(
      receivers: {
        log
          .error(
            """
            error report: \(String(dump: $0),privacy: .public)\
            (\($0.localizedDescription,privacy: .public))\
            \("[\("\($1.file):\($1.function):\($1.line)")]",privacy: .public)
            """
          )
      },
      { err, _ in
        Task { @MainActor in
          self.enqueue(err)
        }
        }
    )
  }
}

#if canImport(SwiftUI)
  import SwiftUI

  extension EnvironmentValues {
    @Entry var errorManager: ErrorManager = .init()
  }

#endif
