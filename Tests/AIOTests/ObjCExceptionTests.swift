// © GoodHatsLLC

@testable import AIOAudioSession
@testable import AIOEngineCore
@testable import AIOSupport
@testable import AudioIO
import Foundation
import Testing
import Tools

/// The Objective-C exception boundary. Nothing above it can be tested by
/// asserting on a failure — an escaped raise aborts the process — so these
/// pin the boundary itself.
@Suite
struct ObjCExceptionTests {
  @Test
  func `a raise is handed back rather than unwound`() {
    let exception = ObjCException.raised {
      NSException(name: .invalidArgumentException, reason: "deliberate", userInfo: nil).raise()
    }

    #expect(exception?.name == .invalidArgumentException)
    #expect(exception?.reason == "deliberate")
  }

  @Test
  func `a block that returns normally reports no exception`() {
    var ran = false

    let exception = ObjCException.raised { ran = true }

    #expect(ran)
    #expect(exception == nil)
  }

  @Test
  func `guarding converts a raise into a typed error`() {
    #expect(
      throws: ObjCExceptionError(
        name: NSExceptionName.rangeException.rawValue,
        reason: "out of bounds",
      ),
    ) {
      try ObjCException.guarding {
        NSException(name: .rangeException, reason: "out of bounds", userInfo: nil).raise()
      }
    }
  }

  @Test
  func `the error survives normalization through ErrorContext`() {
    // The bring-up path funnels errors into `ErrorContext`, which bridges via
    // `NSError`. Without `CustomNSError` the exception's own reason — the part
    // that names the failed condition — would be replaced by a generic
    // description of the Swift type.
    let error = ObjCExceptionError(
      name: "com.apple.coreaudio.avfaudio",
      reason: "required condition is false: inputNode != nullptr || outputNode != nullptr",
    )

    let context = ErrorContext(error)

    #expect(context.domain == "AudioIO.ObjCException")
    #expect(context.message.contains("inputNode != nullptr"))
  }

  @Test
  func `the real graph assertion becomes a transient readiness error`() {
    // Not a synthesized exception: a fresh engine's graph holds only the
    // attached player, so `AVAudioEngineGraph::Initialize` fails its
    // `inputNode != nullptr || outputNode != nullptr` condition. This is the
    // exact abort that reached production; it must now be a classified error.
    let engine = AIOEngine(recordingEnvironment: .live)

    let result = engine.runOnEngineControlQueueResult {
      try engine.prepareGraph("regression probe")
    }

    guard case .failure(let error) = result,
      let recordingError = error as? RecordingError,
      case .session(let sessionError) = recordingError,
      case .notReady(let details) = sessionError
    else {
      Issue.record("expected .session(.notReady), got \(result)")
      return
    }
    #expect(sessionError.isTransient)
    #expect(details.contains("inputNode != nullptr"))
  }

  @Test
  func `the engine control queue turns a raise into a failure`() {
    // Every graph mutation goes through this helper, so it is the floor under
    // the playback and capture starts that only classify a `.failure`.
    let engine = AIOEngine(recordingEnvironment: .live)

    let result: Result<Int, any Error> = engine.runOnEngineControlQueueResult {
      NSException(name: .genericException, reason: "graph precondition", userInfo: nil).raise()
      return 0
    }

    guard case .failure(let error) = result else {
      Issue.record("a raise inside engine-control work must surface as a failure")
      return
    }
    #expect((error as? ObjCExceptionError)?.reason == "graph precondition")
  }
}
