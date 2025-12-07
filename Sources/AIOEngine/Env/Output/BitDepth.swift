public enum BitDepth: Int, CaseIterable, Sendable, Hashable, Identifiable, CustomStringConvertible,
  TypeDescribable, Comparable
{
  case pcm16 = 16
  case pcm24 = 24
  case pcmFloat32 = 32

  public var id: Self { self }

  public static func < (lhs: BitDepth, rhs: BitDepth) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public var description: String {
    switch self {
    case .pcm16: return "16-bit"
    case .pcm24: return "24-bit"
    case .pcmFloat32: return "32-bit"
    }
  }
  public static let typeDescription: String = "Bit Depth"
}
