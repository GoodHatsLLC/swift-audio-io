import AVFAudio

public enum EncodingQuality: Int, CaseIterable, Hashable, CustomStringConvertible, TypeDescribable,
  Identifiable, Sendable
{
  case minimum = 0
  case low = 1
  case medium = 2
  case high = 3
  case maximum = 4
  public var id: Self { self }
  public static let typeDescription: String = "Encoding Quality"

  public var description: String {
    switch self {
    case .minimum: return "Minimum"
    case .low: return "Low"
    case .medium: return "Medium"
    case .high: return "High"
    case .maximum: return "Maximum"
    }
  }

  public var platform: AVAudioQuality {
    switch self {
    case .minimum: AVAudioQuality.min
    case .low: AVAudioQuality.low
    case .medium: AVAudioQuality.medium
    case .high: AVAudioQuality.high
    case .maximum: AVAudioQuality.max
    }
  }
}

extension EncodingQuality: Comparable {
  public static func < (lhs: EncodingQuality, rhs: EncodingQuality) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}
