#if os(iOS)
  public import AVFoundation

  public typealias AudioInterruptionType = AVAudioSession.InterruptionType
  public typealias AudioInterruptionOptions = AVAudioSession.InterruptionOptions
#else
  import Foundation

  public enum AudioInterruptionType: UInt, Sendable, Hashable {
    case began = 1
    case ended = 0
  }

  public struct AudioInterruptionOptions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
      self.rawValue = rawValue
    }

    public static let shouldResume = AudioInterruptionOptions(rawValue: 1 << 0)
  }
#endif
