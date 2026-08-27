// © GoodHatsLLC

internal import AIOObjCException
package import Foundation

/// Recovery for the one failure mode Swift cannot express: an Objective-C
/// exception raised out of a C or C++ frame.
///
/// AVFoundation's audio graph reports precondition violations by raising
/// `NSException` — `AVAudioEngineGraph::Initialize` alone asserts four
/// conditions on the I/O nodes — and a raise that unwinds into Swift aborts
/// the process, whatever `do`/`catch` encloses the call. Typed throws offer no
/// protection here; only an Objective-C `@catch` does.
package enum ObjCException {
  /// Runs `body`, returning the Objective-C exception it raised, or `nil` when
  /// it completed normally.
  ///
  /// - Important: The object that raised is left in an undefined state. Treat
  ///   a non-nil result as a reason to tear that object down and rebuild it,
  ///   never as a reason to retry the same call in place.
  package static func raised(by body: () -> Void) -> NSException? {
    AIOObjCExceptionRaisedBy(body)
  }

  /// Runs `body`, converting an Objective-C raise into a thrown
  /// ``ObjCExceptionError`` so it can travel the same path as any other error.
  package static func guarding(_ body: () -> Void) throws(ObjCExceptionError) {
    if let exception = raised(by: body) {
      throw ObjCExceptionError(exception)
    }
  }
}

/// A caught `NSException`, as an `Error`.
///
/// `CustomNSError` rather than a bare `Error` so that `ErrorContext(_:)` — which
/// normalizes through `NSError` — records the exception's own name and reason
/// instead of a generic bridged description.
package struct ObjCExceptionError: Error, CustomNSError, CustomStringConvertible, Equatable {
  package init(name: String, reason: String?) {
    self.name = name
    self.reason = reason
  }

  package init(_ exception: NSException) {
    self.init(name: exception.name.rawValue, reason: exception.reason)
  }

  package static let errorDomain = "AudioIO.ObjCException"

  /// The exception's `NSExceptionName`, e.g. `com.apple.coreaudio.avfaudio`.
  package let name: String

  /// The exception's reason, e.g. the failed `required condition is false: …`.
  package let reason: String?

  package var errorCode: Int { 0 }

  package var errorUserInfo: [String: Any] {
    [NSLocalizedDescriptionKey: description]
  }

  package var description: String {
    guard let reason else { return name }
    return "\(name): \(reason)"
  }
}
