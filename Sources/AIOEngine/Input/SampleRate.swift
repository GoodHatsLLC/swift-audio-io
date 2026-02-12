public struct SampleRate: RawRepresentable, Hashable, Codable, CustomStringConvertible,
  Identifiable, Sendable, TypeDescribable, Comparable
{
  public var rawValue: RawValue
  public var platform: Double { rawValue }
  public init(rawValue: Double) {
    self.rawValue = rawValue
  }
  public init(common: Common) {
    self.rawValue = common.rawValue
  }
  public static let typeDescription: String = "Sample Rate"
  public var id: Self { self }
  public var description: String {
    "\(platform / 1000.0) kHz"
  }
  public static var commonCases: [SampleRate] {
    SampleRate.Common.allCases.map(SampleRate.init(common:))
  }

  public static func < (lhs: SampleRate, rhs: SampleRate) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}
extension SampleRate {
  public static func common(_ value: Common) -> SampleRate {
    SampleRate(rawValue: value.rawValue)
  }
  public enum Common: Double, CaseIterable, Comparable, Sendable, Codable {
    case sr16000 = 16000
    case sr22050 = 22050
    case sr24000 = 24000
    case sr44100 = 44100
    case sr48000 = 48000
    case sr96000 = 96000
    case sr192000 = 192000

    public static func < (lhs: Common, rhs: Common) -> Bool {
      lhs.rawValue < rhs.rawValue
    }

    public var rate: SampleRate {
      .init(common: self)
    }
  }
}
