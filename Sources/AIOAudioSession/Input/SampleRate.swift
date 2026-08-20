// © GoodHatsLLC

/// A sample rate, in hertz.
///
/// Construct via an integer literal (`let rate: SampleRate = 48_000`), the
/// numeric initializers (`SampleRate(48_000)`), or the named statics
/// (`.cd`, `.dvd`, `.hiRes96`, `.hiRes192`).
///
/// Codable shape: `{ "hz": <Double> }` — keyed container, not a bare scalar.
/// This is a public, persistence-relevant contract.
public struct SampleRate: ExpressibleByIntegerLiteral, Hashable, Codable,
  CustomStringConvertible, Identifiable, Sendable, TypeDescribable, Comparable
{
  /// The sample rate in hertz. AVFoundation APIs accept `Double` sample rates.
  public let hz: Double

  public init(integerLiteral value: Int) {
    self.hz = Double(value)
  }

  public init(_ hz: Double) {
    self.hz = hz
  }

  public init(_ hz: Int) {
    self.hz = Double(hz)
  }

  public static let typeDescription: String = "Sample Rate"

  public var id: Self { self }

  public var description: String {
    "\(hz / 1000.0) kHz"
  }

  public static func < (lhs: SampleRate, rhs: SampleRate) -> Bool {
    lhs.hz < rhs.hz
  }
}

extension SampleRate {
  /// Speech processing — 16 kHz.
  ///
  /// The de-facto speech-to-text target: Whisper's frontend requires it, and
  /// the major cloud STT services document it as optimal. Rates above 16 kHz
  /// add compute and noise bandwidth to a speech pipeline, not accuracy.
  public static let speech: SampleRate = 16_000
  /// Audio CD — 44.1 kHz.
  public static let cd: SampleRate = 44_100
  /// DVD audio / pro audio standard — 48 kHz. The rate modern iPhone
  /// built-in routes actually run at.
  public static let dvd: SampleRate = 48_000
  /// High-resolution audio — 96 kHz.
  public static let hiRes96: SampleRate = 96_000
  /// Maximum high-resolution audio — 192 kHz.
  public static let hiRes192: SampleRate = 192_000

  /// Common sample rates in ascending order. Useful for building UI selectors
  /// when the consumer wants to enumerate standard choices.
  public static let common: [SampleRate] = [
    16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 96_000, 192_000,
  ]
}
