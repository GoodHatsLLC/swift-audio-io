import UniformTypeIdentifiers

public enum FileFormat: String, CaseIterable, CustomStringConvertible, Sendable, Identifiable,
  TypeDescribable
{
  case caf = "caf"
  case wav = "wav"
  case aac = "m4a"
  case adts = "aac"
  case flac = "flac"
  public var id: Self { self }
  public var fileExtension: String { rawValue }
  public static let typeDescription: String = "File Format"

  public var description: String {
    switch self {
    case .adts: return "ADTS"
    case .flac: return "FLAC"
    default: return "\(rawValue)".uppercased()
    }
  }

  public var requiresInterleaved: Bool {
    switch self {
    case .aac, .adts: return true
    case .wav, .caf, .flac: return false
    }
  }

  public var utType: UTType {
    switch self {
    case .aac, .adts: .mpeg4Audio
    case .caf: .audio
    case .wav: .wav
    case .flac: UTType(mimeType: "audio/flac", conformingTo: .audio)!
    }
  }

  public var supportedBitDepths: [BitDepth] {
    switch self {
    case .aac, .adts:
      // Compressed formats should use 16-bit or Float32, not 24-bit
      [BitDepth.pcmFloat32, BitDepth.pcmInt16]
    case .flac:
      // FLAC supports 16-bit and 24-bit PCM
      [BitDepth.pcmInt16, BitDepth.pcmInt24]
    case .wav, .caf:
      // PCM formats support all bit depths
      BitDepth.allCases
    }
  }

  public var requiresQuality: Bool {
    switch self {
    case .aac, .adts: return true
    case .wav, .caf, .flac: return false
    }
  }
}
