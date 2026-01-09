import Foundation

/// A stable, equatable representation of an `Error`.
///
/// Typed-throws APIs in this repo require errors to be `Sendable`, `Equatable`, and
/// `CustomStringConvertible`. Most system error types are not `Equatable`, so we
/// normalize them into `(domain, code, message)`.
public struct ErrorContext: Sendable, Equatable, Hashable, CustomStringConvertible {
  public init(domain: String, code: Int, message: String) {
    self.domain = domain
    self.code = code
    self.message = message
  }

  public init(_ error: any Error) {
    let nsError = error as NSError
    self.domain = nsError.domain
    self.code = nsError.code
    self.message = nsError.localizedDescription
  }

  public let domain: String
  public let code: Int
  public let message: String

  public var description: String {
    "\(domain)(\(code)): \(message)"
  }
}

