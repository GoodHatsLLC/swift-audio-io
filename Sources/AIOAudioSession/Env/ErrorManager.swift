// © GoodHatsLLC

import AIOSupport
public import Foundation
public import Observation
public import Tools
import os

private let log = SystemLog.make()

@Observable
public final class ErrorManager: Sendable {
  @ObservationIgnored private let errorEventsSubject = Subject<ErrorEvent>()
  @ObservationIgnored private let eventTasks = AsyncTaskRunner()

  public nonisolated init() {}

  public struct ErrorEvent: Identifiable, Hashable, Sendable {
    public enum Visibility: Sendable {
      /// Visible only when debug toasts are enabled.
      case debug
      /// Visible to users because it interrupts an expected interaction.
      case userInterrupting
    }

    public init(
      error: any Error,
      visibility: Visibility,
      userMessage: String? = nil,
      context: String? = nil,
      source: SourceLocation,
    ) {
      self.visibility = visibility
      self.userMessage = userMessage
      self.context = context
      self.source = source
      localizedDescription = error.localizedDescription
      debugDump = String(dump: error)
      typeName = String(reflecting: type(of: error))
    }

    public let id: UUID = .init()
    public let visibility: Visibility
    public let userMessage: String?
    public let context: String?
    public let source: SourceLocation
    public let localizedDescription: String
    public let debugDump: String
    public let typeName: String

    public var debugToastText: String {
      let prefix = context.map { "\($0): " } ?? ""
      return "\(prefix)\(localizedDescription)"
    }

    public var userToastText: String {
      userMessage ?? localizedDescription
    }
  }

  @MainActor
  public var errors: [ErrorEvent] = []

  public var eventStream: AsyncBroadcaster<ErrorEvent> {
    errorEventsSubject.broadcaster
  }

  @MainActor
  public func popError() -> ErrorEvent? {
    if !errors.isEmpty {
      errors.removeFirst()
    } else {
      nil
    }
  }

  public nonisolated func enqueue(
    _ error: any Error,
    visibility: ErrorEvent.Visibility = .userInterrupting,
    userMessage: String? = nil,
    context: String? = nil,
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    column: Int = #column,
  ) {
    let source = SourceLocation(file: file, function: function, line: line, column: column)
    log.error(
      """
      error enqueued: \(String(dump: error), privacy: .public)\
      (\(error.localizedDescription, privacy: .public))\
      \("[\(source.file):\(source.function):\(source.line)]", privacy: .public)
      """,
    )
    let event = ErrorEvent(
      error: error,
      visibility: visibility,
      userMessage: userMessage,
      context: context,
      source: source,
    )
    eventTasks.run { [weak self, event] in
      await MainActor.run {
        guard let self else { return }
        self.errors.append(event)
        self.errorEventsSubject.send(event)
      }
    }
  }

  public func reporter(
    visibility: ErrorEvent.Visibility,
    userMessage: String? = nil,
    context: String? = nil,
  ) -> Reporter<any Error> {
    .init(
      receivers: {
        log
          .error(
            """
            error report: \(String(dump: $0), privacy: .public)\
            (\($0.localizedDescription, privacy: .public))\
            \("[\("\($1.file):\($1.function):\($1.line)")]", privacy: .public)
            """,
          )
      },
      { err, _ in
        self.enqueue(
          err,
          visibility: visibility,
          userMessage: userMessage,
          context: context,
        )
      },
    )
  }

  public var report: Reporter<any Error> {
    reporter(visibility: .userInterrupting)
  }

  public var debugReport: Reporter<any Error> {
    reporter(visibility: .debug)
  }
}
