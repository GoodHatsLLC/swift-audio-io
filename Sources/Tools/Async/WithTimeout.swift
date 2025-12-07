import os

// MARK: - Timeout

/// A function that executes an asynchronous operation with a timeout.
public struct Timeout: Error {

  let fromLocation: SourceLocation
  let afterDuration: Duration
  let type: String

  public var description: String {
    "withTimeout<\(type)> invocation at \(fromLocation.short) timed out after ~\(String(format: "%.2f", afterDuration.seconds)) seconds."
  }
}

/// A timeout with triggers for async work.
///
/// - Parameters:
///   - duration: The duration to wait before timing out.
///   - operation: The operation to execute.
/// - Returns: The result of the operation, if any.
/// - Throws: `Timeout` if the operation times out, the error thrown by the operation, or `CancellationError` if
/// surrounding task context is cancelled.
public func withTimeout<Return: Sendable, Failure: Error>(
  of duration: Duration,
  file: StaticString = #file,
  line: UInt = #line,
  column _: UInt = #column,
  function: StaticString = #function,
  _ operation: @Sendable @escaping @isolated(any) () async throws(Failure) -> Return
) async throws
  -> Return
{
  let location = SourceLocation(file: file, fun: function, line: line)
  let result = await withTaskGroup(of: Either<Result<Return, Failure>, Timeout>.self) { group in
    group.addTask {
      try? await Task.sleep(for: duration)
      return .rhs(Timeout(fromLocation: location, afterDuration: duration, type: "\(Return.self)"))
    }

    let run: () async throws(Failure) -> Return = { () async throws(Failure) -> Return in
      try await operation()
    }

    group.addTask {

      do {
        let ret = try await run()
        return .lhs(Result<Return, Failure>.success(ret))
      } catch {
        return .lhs(Result<Return, Failure>.failure(error as! Failure))
      }
    }
    let initial = await group.next()
    defer { group.cancelAll() }
    return initial
  }
  switch result {
  case .none: throw CancellationError()
  case .lhs(.success(let value)):
    return value
  case .lhs(.failure(let error)):
    throw error
  case .rhs(let timeout):
    throw timeout
  }
}

// MARK: - Flag

private actor Flag {
  var value: Bool = false

  func set(value: Bool) {
    self.value = value
  }

  func performIf(expected: Bool, perform: @Sendable () -> Bool) {
    if value == expected {
      value = perform()
    }
  }
}

public struct SourceLocation: Sendable, Hashable, Codable, CustomStringConvertible {
  public init(
    file: StaticString = #file,
    fun: StaticString = #function,
    line: UInt = #line,
    col: UInt = #column,
    _ comment: Any = ""
  ) {
    self.file = file.description
    self.fun = fun.description
    self.line = line
    self.col = col
    self.comment = "\(comment.self)"
  }

  public var description: String {
    "\(comment)#\(file):\(line):\(col):\(fun)"
  }

  public var short: String {
    "\(file):\(line)"
  }

  let file: String
  let fun: String
  let line: UInt
  let col: UInt
  let comment: String
}

private enum Either<LHS, RHS> {
  case lhs(LHS)
  case rhs(RHS)
}
extension Either: Sendable where LHS: Sendable, RHS: Sendable {}
