import Dispatch

#if canImport(Foundation)
import Foundation
let prefix = Bundle.main.bundleIdentifier ?? "com.app"
#else
let prefix = "com.app"
#endif



public final class BackgroundSerialExecutor: TaskExecutor, SerialExecutor, Sendable {
  private let queue = DispatchQueue(
    label: "\(prefix).BackgroundSerialExecutor",
    qos: .background
  )
  public func enqueue(_ job: UnownedJob) {
    let unowned = asUnownedSerialExecutor()
    queue.async {
      job.runSynchronously(on: unowned)
    }
  }
}

public extension SerialExecutor where Self == BackgroundSerialExecutor {
  static var serialBackground: BackgroundSerialExecutor {
    Background.executor
  }
}

@globalActor
public actor Background {
  public static let executor = BackgroundSerialExecutor()
  public static let shared: some Actor = Background()
  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    Self.executor.asUnownedSerialExecutor()
  }
}

