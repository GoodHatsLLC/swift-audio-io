import AVFAudio
import Foundation

public enum AIOError: Error, Hashable, Sendable {
  case unknown(NSError)
  case audioSession(AudioSessionError)
}

extension AIOError {

  /// `AVAudioSession.ErrorCode`
  public enum AudioSessionError: Int, Sendable {
    case none = 0
    case unknownDefaultError = -999
    case mediaServicesFailed = 1_836_282_486
    case isBusy = 560_030_580
    case incompatibleCategory = 560_161_140
    case cannotInterruptOthers = 560_557_684
    case missingEntitlement = 1_701_737_535
    case siriIsRecording = 1_936_290_409
    case cannotStartPlaying = 561_015_905
    case cannotStartRecording = 561_145_187
    case badParam = -50
    case insufficientPriority = 561_017_449
    case resourceNotAvailable = 561_145_203
    case unspecified = 2_003_329_396
    case expiredSession = 561_210_739
    case sessionNotActive = 1_768_841_571

  }
}

#if !os(macOS)
extension AIOError.AudioSessionError {
  init?(code: AVAudioSession.ErrorCode) {
    switch code {
    case .none:
      self = .none
    case .mediaServicesFailed:
      self = .mediaServicesFailed
    case .isBusy:
      self = .isBusy
    case .incompatibleCategory:
      self = .incompatibleCategory
    case .cannotInterruptOthers:
      self = .cannotInterruptOthers
    case .missingEntitlement:
      self = .missingEntitlement
    case .siriIsRecording:
      self = .siriIsRecording
    case .cannotStartPlaying:
      self = .cannotStartPlaying
    case .cannotStartRecording:
      self = .cannotStartRecording
    case .badParam:
      self = .badParam
    case .insufficientPriority:
      self = .insufficientPriority
    case .resourceNotAvailable:
      self = .resourceNotAvailable
    case .unspecified:
      self = .unspecified
    case .expiredSession:
      self = .expiredSession
    case .sessionNotActive:
      self = .sessionNotActive
    default:
      return nil
    }
  }
}
#endif
