// © GoodHatsLLC

public enum BitDepth: Int, CaseIterable, Sendable, Hashable, Identifiable, CustomStringConvertible,
  TypeDescribable, Comparable
{
  case pcmInt16 = 16
  case pcmInt24 = 24
  case pcmFloat32 = 32

  public var id: Self {
    self
  }

  public static func < (lhs: BitDepth, rhs: BitDepth) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public var description: String {
    switch self {
    case .pcmInt16: "16-bit"
    case .pcmInt24: "24-bit"
    case .pcmFloat32: "32-bit"
    }
  }

  public static let typeDescription: String = "Bit Depth"
}
