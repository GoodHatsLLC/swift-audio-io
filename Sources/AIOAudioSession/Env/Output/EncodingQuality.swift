// © GoodHatsLLC

public import AVFAudio

public enum EncodingQuality: Int, CaseIterable, Hashable, CustomStringConvertible, TypeDescribable,
  Identifiable, Sendable
{
  case minimum = 0
  case low = 1
  case medium = 2
  case high = 3
  case maximum = 4
  public var id: Self {
    self
  }

  public static let typeDescription: String = "Encoding Quality"

  public var description: String {
    switch self {
    case .minimum: "Minimum"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .maximum: "Maximum"
    }
  }

  /// AVFoundation escape hatch — bridges the AIO enum to its
  /// `AVAudioQuality` counterpart. Use this when constructing
  /// AVAudioRecorder settings or interoperating with AVFoundation APIs
  /// directly. Mainstream consumers should compose
  /// ``RecordingConfiguration`` and let AIO emit the file settings.
  @_spi(AVFoundation)
  public var avAudio: AVAudioQuality {
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
