public import Foundation

extension String {
  public init<T>(dump value: @autoclosure () -> T) {
    var output = ""
    dump(value(), to: &output)
    self = output
  }
}

public struct SourceLocation: Sendable, Hashable {
  public init(file: String, function: String, line: Int, column: Int) {
    self.file = file
    self.function = function
    self.line = line
    self.column = column
  }

  public let file: String
  public let function: String
  public let line: Int
  public let column: Int
}

public struct Reporter<E: Error> {
  public init(receivers: (E, SourceLocation) -> Void...) {
    self.receivers = receivers
  }

  private let receivers: [(E, SourceLocation) -> Void]

  @discardableResult
  public func callAsFunction<V: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    column: Int = #column,
    @_inheritActorContext(always) _ operation: sending @isolated(any) () async throws(E) -> V
  ) async throws(E) -> V where E: Error {
    _ = isolation
    let source = SourceLocation(file: file, function: function, line: line, column: column)
    do {
      return try await operation()
    } catch {
      if error is CancellationError {
        throw error
      }
      for receiver in receivers {
        receiver(error, source)
      }
      throw error
    }
  }

  @discardableResult
  public func callAsFunction<V>(
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    column: Int = #column,
    _ operation: () throws(E) -> V
  ) throws(E) -> V where E: Error {
    let source = SourceLocation(file: file, function: function, line: line, column: column)
    do {
      return try operation()
    } catch {
      if error is CancellationError {
        throw error
      }
      for receiver in receivers {
        receiver(error, source)
      }
      throw error
    }
  }

  @discardableResult
  public func callAsFunction<V: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    column: Int = #column,
    @_inheritActorContext(always) _ operation: sending @isolated(any) () async throws(E) -> V,
    catch catchBlock: (_ error: E) -> Void
  ) async -> V? {
    _ = isolation
    let source = SourceLocation(file: file, function: function, line: line, column: column)
    do {
      return try await operation()
    } catch {
      if error is CancellationError {
        return nil
      }
      for receiver in receivers {
        receiver(error, source)
      }
      catchBlock(error)
      return nil
    }
  }

  @discardableResult
  public func callAsFunction<V>(
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    column: Int = #column,
    _ operation: () throws(E) -> V,
    catch catchBlock: (_ error: E) -> Void
  ) -> V? {
    let source = SourceLocation(file: file, function: function, line: line, column: column)
    do {
      return try operation()
    } catch {
      if error is CancellationError {
        return nil
      }
      for receiver in receivers {
        receiver(error, source)
      }
      catchBlock(error)
      return nil
    }
  }
}

public enum ReportedError: Error, LocalizedError, Sendable, Equatable, CustomStringConvertible {
  case cancelled
  case error(description: String)

  public var description: String {
    switch self {
    case .cancelled:
      return "Operation cancelled"
    case .error(let description):
      return description
    }
  }

  public var errorDescription: String? { description }
}

extension Reporter where E == any Error {
  @discardableResult
  public func callAsFunction<V: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    column: Int = #column,
    @_inheritActorContext(always) _ operation:
      sending @isolated(any) () async throws(any Error) -> V
  ) async throws(ReportedError) -> V {
    _ = isolation
    let source = SourceLocation(file: file, function: function, line: line, column: column)
    do {
      return try await operation()
    } catch {
      if error is CancellationError {
        throw .cancelled
      }
      for receiver in receivers {
        receiver(error, source)
      }
      throw .error(description: String(describing: error))
    }
  }

  @discardableResult
  public func callAsFunction<V>(
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    column: Int = #column,
    _ operation: () throws(any Error) -> V
  ) throws(ReportedError) -> V {
    let source = SourceLocation(file: file, function: function, line: line, column: column)
    do {
      return try operation()
    } catch {
      if error is CancellationError {
        throw .cancelled
      }
      for receiver in receivers {
        receiver(error, source)
      }
      throw .error(description: String(describing: error))
    }
  }
}
