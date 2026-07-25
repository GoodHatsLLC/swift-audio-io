// © GoodHatsLLC

public import Foundation

extension String {
  public init(dump value: @autoclosure () -> some Any) {
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

  @_disfavoredOverload
  @discardableResult
  public func callAsFunction<V: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    column: Int = #column,
    @_inheritActorContext(always) _ operation: sending @isolated(any) () async throws(E) -> V,
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
    _ operation: () throws(E) -> V,
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

  @_disfavoredOverload
  @discardableResult
  public func callAsFunction<V: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    file: String = #file,
    function: String = #function,
    line: Int = #line,
    column: Int = #column,
    @_inheritActorContext(always) _ operation: sending @isolated(any) () async throws(E) -> V,
    catch catchBlock: (_ error: E) -> Void,
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
    catch catchBlock: (_ error: E) -> Void,
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
      "Operation cancelled"
    case .error(let description):
      description
    }
  }

  public var errorDescription: String? {
    description
  }
}

// NOTE: There is deliberately no `extension Reporter where E == any Error`
// overload set here. `throws(E)` with `E == any Error` is spelled `throws`, so
// any such overload has a signature identical to the generic one above once the
// constraint is substituted, and the two can only be ranked by
// `@_disfavoredOverload`. Swift 6.4 (Xcode 27) no longer breaks that tie via
// constrained-extension specialization, making every `Reporter<any Error>` call
// site ambiguous. The generic overloads cover `E == any Error` and rethrow the
// original error, which preserves error identity (including `CancellationError`)
// rather than flattening it into a described `ReportedError`.
