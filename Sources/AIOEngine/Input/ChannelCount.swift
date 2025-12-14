#if canImport(AVFoundation)
  import AVFoundation

  public struct ChannelCount: Sendable, Hashable, Identifiable,
    CustomStringConvertible, TypeDescribable, Comparable
  {

    public init(platform: AVAudioChannelCount) {
      self.platform = platform
    }

    let platform: AVAudioChannelCount

    public static let typeDescription: String = "Channel Count"

    public static func < (lhs: ChannelCount, rhs: ChannelCount) -> Bool {
      lhs.platform < rhs.platform
    }

    public var id: Self { self }

    public var count: Int {
      Int(platform)
    }

    public static let mono: ChannelCount = .init(platform: 1)
    public static let stereo: ChannelCount = .init(platform: 2)

    public var description: String {
      switch self.platform {
      case 1:
        return "Mono"
      case 2:
        return "Stereo"
      default:
        return "Spacial"
      }
    }
  }
#endif
