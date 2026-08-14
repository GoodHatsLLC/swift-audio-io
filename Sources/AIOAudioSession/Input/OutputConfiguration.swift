// © GoodHatsLLC

public struct OutputConfiguration: CustomStringConvertible,
  Hashable, Identifiable, Sendable
{
  public var id: Self {
    self
  }

  public var description: String {
    var parts: [String] = []
    if let bitDepth {
      parts.append("\(bitDepth)")
    }
    if fileFormat.usesEncodingQuality {
      parts.append("\(quality)")
    }
    parts.append(".\(fileFormat)")
    return parts.joined(separator: " ")
  }

  /// Creates an output encoding.
  ///
  /// - Parameters:
  ///   - fileFormat: The container and codec to write.
  ///   - bitDepth: The written sample width, or the FLAC encoder's bit-depth
  ///     hint. Pass `nil` — and only `nil` — for formats whose
  ///     ``FileFormat/usesBitDepth`` is `false`; the AAC family has no sample
  ///     width to choose, and a value there describes nothing about the file.
  ///   - quality: The encoder quality level for lossy formats. Ignored, and
  ///     reported as ignored by ``FileFormat/usesEncodingQuality``, for the
  ///     lossless ones.
  public init(fileFormat: FileFormat, bitDepth: BitDepth?, quality: EncodingQuality) {
    self.fileFormat = fileFormat
    self.bitDepth = bitDepth
    self.quality = quality
  }

  public let fileFormat: FileFormat

  /// The written sample width, or `nil` when the format decides for itself.
  ///
  /// `nil` is the correct and only valid value for the AAC family. See
  /// ``FileFormat/usesBitDepth``.
  public let bitDepth: BitDepth?

  /// The encoder quality level for lossy formats.
  ///
  /// This is an `AVAudioQuality` level, **not** a bitrate: AudioIO does not
  /// expose `AVEncoderBitRateKey`, and the encoder chooses the bitrate that
  /// serves the requested quality at the configured sample rate and channel
  /// count. Two recordings at ``EncodingQuality/high`` are therefore not
  /// guaranteed to share a bitrate. It reaches the file only when
  /// ``FileFormat/usesEncodingQuality`` is `true`.
  public let quality: EncodingQuality

  /// Whether the bit-depth and quality choices are coherent with the file
  /// format, ignoring the capture format.
  ///
  /// Prefer ``validate(against:)``, which also checks the sample rate and
  /// channel count the capture will actually deliver.
  public var isSupported: Bool {
    validateOutputOnly().isValid
  }
}
