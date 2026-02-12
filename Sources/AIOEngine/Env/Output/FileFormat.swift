public import UniformTypeIdentifiers

public enum FileFormat: String, CaseIterable, CustomStringConvertible, Sendable, Identifiable,
  TypeDescribable
{
  case caf = "caf"
  case wav = "wav"
  case aiff = "aiff"
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
    case .aac, .adts, .aiff: return true
    case .wav, .caf, .flac: return false
    }
  }

  public var utType: UTType {
    switch self {
    case .aac, .adts: .mpeg4Audio
    case .caf: UTType(filenameExtension: "caf") ?? .audio
    case .wav: .wav
    case .aiff: .aiff
    case .flac:
      UTType(filenameExtension: "flac")
        ?? UTType(mimeType: "audio/flac", conformingTo: .audio)
        ?? .audio
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
    case .wav, .caf, .aiff:
      // PCM formats support all bit depths
      BitDepth.allCases
    }
  }

  public var requiresQuality: Bool {
    switch self {
    case .aac, .adts: return true
    case .wav, .caf, .flac, .aiff: return false
    }
  }

  /// Common encoded sample rates supported by AAC-family formats.
  public static let aacCompatibleSampleRates: [Double] = [
    8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000,
  ]

  /// Returns whether this output format supports the given sample rate.
  ///
  /// This reflects current engine-level recording constraints.
  public func supportsEncodedSampleRate(_ sampleRate: Double) -> Bool {
    guard sampleRate.isFinite, sampleRate > 0 else { return false }
    switch self {
    case .aac, .adts:
      return Self.aacCompatibleSampleRates.contains(where: { abs($0 - sampleRate) < 0.5 })
    case .wav, .caf, .aiff:
      return sampleRate >= 8000 && sampleRate <= 192000
    case .flac:
      return sampleRate >= 8000 && sampleRate <= 655350
    }
  }

  public func supports(sampleRate: SampleRate) -> Bool {
    supportsEncodedSampleRate(sampleRate.rawValue)
  }

  public var compatibleCommonSampleRates: [SampleRate] {
    SampleRate.commonCases.filter { supports(sampleRate: $0) }
  }
}
