import Foundation

/// Represents a semantic recording filename with UTC timestamp and identifier.
///
/// Format: `YYYYMMDDTHHmmss_word.ext`
/// - UTC ISO 8601 basic format timestamp (zero-padded to the second)
/// - Underscore separator
/// - Lowercase alphanumeric word for entropy/identification
/// - File extension
///
/// Example: `20251216T143052_bix.aac`
public struct RecordingFilename: Sendable, Equatable, Hashable {

  /// The UTC timestamp of the recording.
  public let timestamp: Date

  /// The identifier word (lowercase alphanumeric).
  public let word: String

  /// The file extension (without dot).
  public let fileExtension: String

  /// Creates a new recording filename with a random phonetic word.
  ///
  /// - Parameters:
  ///   - timestamp: The UTC timestamp of the recording. Defaults to now.
  ///   - fileExtension: The file extension (without dot).
  public init(
    timestamp: Date = Date(),
    fileExtension: String
  ) {
    self.timestamp = timestamp
    self.word = Self.generatePhoneticWord()
    self.fileExtension = fileExtension.lowercased()
  }

  /// Creates a new recording filename with a specific word.
  ///
  /// - Parameters:
  ///   - timestamp: The UTC timestamp of the recording.
  ///   - word: The identifier word (will be lowercased and filtered to alphanumeric).
  ///   - fileExtension: The file extension (without dot).
  public init(
    timestamp: Date,
    word: String,
    fileExtension: String
  ) {
    self.timestamp = timestamp
    self.word = word.lowercased().filter { $0.isLetter || $0.isNumber }
    self.fileExtension = fileExtension.lowercased()
  }

  /// The filename string (without path).
  ///
  /// Example: `20251216T143052_rec.aac`
  public var filename: String {
    let timestampString = Self.formatter.string(from: timestamp)
    return "\(timestampString)_\(word).\(fileExtension)"
  }

  /// The filename string without extension.
  ///
  /// Example: `20251216T143052_rec`
  public var stem: String {
    let timestampString = Self.formatter.string(from: timestamp)
    return "\(timestampString)_\(word)"
  }
}

// MARK: - Parsing

extension RecordingFilename {

  /// Attempts to parse a filename string into a RecordingFilename.
  ///
  /// - Parameter string: The filename string (with or without extension).
  /// - Returns: A parsed RecordingFilename, or `nil` if the format doesn't match.
  public init?(parsing string: String) {
    // Split off extension if present
    let components = string.split(separator: ".", maxSplits: 1)
    let stem = String(components[0])
    let ext = components.count > 1 ? String(components[1]).lowercased() : ""

    // Parse stem: YYYYMMDDTHHmmss_word
    guard let parsed = Self.parseStem(stem) else {
      return nil
    }

    self.timestamp = parsed.timestamp
    self.word = parsed.word
    self.fileExtension = ext
  }

  /// Checks if a filename string matches the recording filename pattern.
  ///
  /// - Parameter string: The filename string to check.
  /// - Returns: `true` if the string matches the pattern.
  public static func matches(_ string: String) -> Bool {
    let components = string.split(separator: ".", maxSplits: 1)
    let stem = String(components[0])
    return parseStem(stem) != nil
  }

  /// Parses the stem (filename without extension) into components.
  private static func parseStem(_ stem: String) -> (timestamp: Date, word: String)? {
    // Minimum length: 15 (timestamp) + 1 (_) + 1 (word) = 17
    guard stem.count >= 17 else { return nil }

    // Check timestamp format: YYYYMMDDTHHmmss (15 chars)
    let timestampPart = String(stem.prefix(15))
    guard timestampPart.count == 15,
      timestampPart.prefix(8).allSatisfy(\.isNumber),
      timestampPart.dropFirst(8).first == "T",
      timestampPart.dropFirst(9).allSatisfy(\.isNumber)
    else {
      return nil
    }

    // Check underscore separator
    guard stem.dropFirst(15).first == "_" else { return nil }

    // Extract word (everything after the underscore)
    let wordPart = String(stem.dropFirst(16))
    guard !wordPart.isEmpty,
      wordPart.allSatisfy({ $0.isLetter || $0.isNumber })
    else {
      return nil
    }

    // Parse timestamp
    guard let timestamp = formatter.date(from: timestampPart) else {
      return nil
    }

    return (timestamp: timestamp, word: wordPart.lowercased())
  }
}

// MARK: - CustomStringConvertible

extension RecordingFilename: CustomStringConvertible {
  public var description: String { filename }
}

// MARK: - LosslessStringConvertible

extension RecordingFilename: LosslessStringConvertible {
  public init?(_ description: String) {
    self.init(parsing: description)
  }
}

// MARK: - Codable

extension RecordingFilename: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let string = try container.decode(String.self)
    guard let parsed = RecordingFilename(parsing: string) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid recording filename format: \(string)"
      )
    }
    self = parsed
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(filename)
  }
}

// MARK: - Formatter

extension RecordingFilename {
  /// ISO 8601 basic format formatter: `YYYYMMDDTHHmmss` (UTC, no separators).
  private final class FormatterBox: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter

    init() {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
      formatter.timeZone = TimeZone(identifier: "UTC")
      self.formatter = formatter
    }

    func string(from date: Date) -> String {
      lock.lock()
      defer { lock.unlock() }
      return formatter.string(from: date)
    }

    func date(from string: String) -> Date? {
      lock.lock()
      defer { lock.unlock() }
      return formatter.date(from: string)
    }
  }

  private static let formatter = FormatterBox()
}

// MARK: - Phonetic Word Generation

extension RecordingFilename {

  /// Generates a random pronounceable word using CVC (consonant-vowel-consonant) pattern.
  ///
  /// Examples: "bix", "tov", "mup", "zaf", "ked"
  ///
  /// Entropy: 20 × 5 × 20 = 2000 combinations per syllable
  private static func generatePhoneticWord() -> String {
    // Consonants that work well at start and end of syllables
    let consonants: [Character] = [
      "b", "d", "f", "g", "h", "k", "l", "m",
      "n", "p", "r", "s", "t", "v", "w", "z"
    ]

    // Simple vowels for clear pronunciation
    let vowels: [Character] = ["a", "e", "i", "o", "u"]

    // Generate a single CVC syllable (3 chars, 1600 combinations)
    let c1 = consonants.randomElement()!
    let v = vowels.randomElement()!
    let c2 = consonants.randomElement()!

    return String([c1, v, c2])
  }
}
