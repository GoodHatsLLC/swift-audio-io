import Observation
import SystemLog

/// A narrow, injectable interface for error reporting.
///
/// - View layer may access a concrete `ErrorManager` via SwiftUI environment.
/// - Business logic should depend on `any ErrorManaging` (injected), not `ErrorManager` directly.
public protocol ErrorManaging: Sendable {
  @MainActor
  func enqueue(
    _ error: any Error,
    visibility: ErrorManager.ErrorEvent.Visibility,
    userMessage: String?,
    context: String?,
    source: SourceLocation
  )

  func reporter(
    visibility: ErrorManager.ErrorEvent.Visibility,
    userMessage: String?,
    context: String?
  ) -> Reporter<any Error>
}

extension ErrorManaging {
  @MainActor
  public func enqueue(
    _ error: any Error,
    visibility: ErrorManager.ErrorEvent.Visibility = .userInterrupting,
    userMessage: String? = nil,
    context: String? = nil,
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    column: Int = #column
  ) {
    let source = SourceLocation(file: file, function: function, line: line, column: column)
    enqueue(
      error,
      visibility: visibility,
      userMessage: userMessage,
      context: context,
      source: source
    )
  }

  public func reporter(
    visibility: ErrorManager.ErrorEvent.Visibility,
    userMessage: String? = nil,
    context: String? = nil
  ) -> Reporter<any Error> {
    .init { err, sl in
      Task { @MainActor in
        self.enqueue(
          err,
          visibility: visibility,
          userMessage: userMessage,
          context: context,
          source: sl
        )
      }
    }
  }

  public var report: Reporter<any Error> {
    reporter(visibility: .userInterrupting)
  }

  public var debugReport: Reporter<any Error> {
    reporter(visibility: .debug)
  }
}

/// A simple type-erasing wrapper for any `ErrorManaging` implementation.
public struct AnyErrorManager: ErrorManaging {
  private let base: any ErrorManaging

  public init(_ base: any ErrorManaging) {
    self.base = base
  }

  @MainActor
  public func enqueue(
    _ error: any Error,
    visibility: ErrorManager.ErrorEvent.Visibility,
    userMessage: String?,
    context: String?,
    source: SourceLocation
  ) {
    base.enqueue(
      error,
      visibility: visibility,
      userMessage: userMessage,
      context: context,
      source: source
    )
  }

  public func reporter(
    visibility: ErrorManager.ErrorEvent.Visibility,
    userMessage: String?,
    context: String?
  ) -> Reporter<any Error> {
    base.reporter(visibility: visibility, userMessage: userMessage, context: context)
  }
}

extension ErrorManager {
  @MainActor
  public func enqueue(
    _ error: any Error,
    visibility: ErrorEvent.Visibility,
    userMessage: String?,
    context: String?,
    source: SourceLocation
  ) {
    enqueue(
      error,
      visibility: visibility,
      userMessage: userMessage,
      context: context,
      file: source.file,
      function: source.function,
      line: source.line,
      column: source.column
    )
  }
}

extension ErrorManager: ErrorManaging {}

#if DEBUG
  /// A lightweight error manager for tests.
  ///
  /// Stores enqueued errors for later inspection without any UI coupling.
  @Observable
  public final class MockErrorManager: Sendable, ErrorManaging {
    public nonisolated init() {}

    @MainActor
    public private(set) var events: [ErrorManager.ErrorEvent] = []

    @MainActor
    public func enqueue(
      _ error: any Error,
      visibility: ErrorManager.ErrorEvent.Visibility,
      userMessage: String?,
      context: String?,
      source: SourceLocation
    ) {
      events.append(
        ErrorManager.ErrorEvent(
          error: error,
          visibility: visibility,
          userMessage: userMessage,
          context: context,
          source: source
        )
      )
    }

    @MainActor
    public func popEvent() -> ErrorManager.ErrorEvent? {
      if !events.isEmpty {
        return events.removeFirst()
      }
      return nil
    }

    @MainActor
    public func reset() {
      events.removeAll()
    }
  }
#endif
