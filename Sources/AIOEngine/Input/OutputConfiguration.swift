public struct OutputConfiguration: CustomStringConvertible,
  Hashable, Identifiable, Sendable
{
  public var id: Self { self }
  public var description: String {
    "\(bitDepth) \(quality) .\(fileFormat)"
  }
  public init(fileFormat: FileFormat, bitDepth: BitDepth, quality: EncodingQuality) {
    self.fileFormat = fileFormat
    self.bitDepth = bitDepth
    self.quality = quality
  }
  public let fileFormat: FileFormat
  public let bitDepth: BitDepth
  public let quality: EncodingQuality

  public var isSupported: Bool {
    fileFormat.supportedBitDepths.contains(bitDepth)
  }
}
