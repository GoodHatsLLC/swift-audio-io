#if canImport(Observation)
import Observation
import SystemLog

private let log = SystemLog.make()

@Observable
@MainActor
public final class ErrorManager {
  public init() {}
  public private(set) var errors: [any Error] = []
  public func popError() -> (any Error)? {
    if !errors.isEmpty {
      errors.removeFirst()
    } else {
      nil
    }
  }
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
      { err, _ in self.enqueue(err) }
    )
  }
}
#endif
