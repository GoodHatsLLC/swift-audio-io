// © GoodHatsLLC

package import AVFAudio
import AudioToolbox
import Foundation
public import UniformTypeIdentifiers

public enum FileFormat: String, CaseIterable, CustomStringConvertible, Sendable, Identifiable,
  TypeDescribable
{
  case caf
  case wav
  case aiff
  case aac = "m4a"
  case adts = "aac"
  case flac
  public var id: Self {
    self
  }

  public var fileExtension: String {
    rawValue
  }

  public static let typeDescription: String = "File Format"

  public var description: String {
    switch self {
    case .adts: "ADTS"
    case .flac: "FLAC"
    default: "\(rawValue)".uppercased()
    }
  }

  public var requiresInterleaved: Bool {
    switch self {
    case .aac, .adts, .aiff: true
    case .wav, .caf, .flac: false
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

  /// The bit depths this format's writer can actually use, in ascending order.
  ///
  /// Empty for the AAC family. AAC is a lossy transform codec: it has no PCM
  /// sample width to choose, its file settings carry no bit-depth key, and the
  /// capture pipeline feeding it is Float32 either way. Reporting depths here
  /// would put a control in front of a user that changes nothing about the
  /// file — which is what this property used to do.
  ///
  /// For FLAC the values are a lossless *encoder hint*
  /// (`AVEncoderBitDepthHintKey`), not a container sample width; for the PCM
  /// containers they are the written sample width exactly. Either way the
  /// choice reaches the file, which is the line this property draws.
  public var supportedBitDepths: [BitDepth] {
    switch self {
    case .aac, .adts:
      []
    case .flac:
      // FLAC supports 16-bit and 24-bit PCM
      [BitDepth.pcmInt16, BitDepth.pcmInt24]
    case .wav, .caf, .aiff:
      // PCM formats support all bit depths
      BitDepth.allCases
    }
  }

  /// Whether ``BitDepth`` means anything for this format. `false` for the AAC
  /// family; a caller should leave ``OutputConfiguration/bitDepth`` `nil`, and
  /// a UI should offer no control.
  public var usesBitDepth: Bool {
    !supportedBitDepths.isEmpty
  }

  /// Whether ``EncodingQuality`` reaches this format's writer.
  ///
  /// `true` only for the lossy AAC family, whose settings carry
  /// `AVEncoderAudioQualityKey`. The lossless formats ignore it entirely.
  public var usesEncodingQuality: Bool {
    switch self {
    case .aac, .adts: true
    case .wav, .caf, .flac, .aiff: false
    }
  }

  /// Whether a file truncated mid-write remains valid up to the truncation
  /// point — i.e. whether the format is self-framing rather than dependent on
  /// a header or index finalized at close.
  ///
  /// Only ADTS qualifies: every AAC frame carries its own header, so a reader
  /// can resynchronize from any point. The PCM containers all declare a data
  /// length in a header written at close, and `m4a` has no `moov` atom until
  /// then. FLAC is reported conservatively: its frames carry sync codes, so
  /// many decoders will play a truncated stream, but `STREAMINFO`'s
  /// total-samples field and the seektable are finalized at close, which makes
  /// the outcome decoder-dependent.
  ///
  /// A consumer rotating files for crash-safety wants this to be `false`.
  public var toleratesTruncation: Bool {
    switch self {
    case .adts: true
    case .aac, .wav, .caf, .aiff, .flac: false
    }
  }

  /// Whether decoding the written file yields exactly the frames that were
  /// written, with no encoder priming or trailing padding.
  ///
  /// The PCM containers and FLAC are frame-exact. AAC — in either container —
  /// is not: the encoder prepends priming frames and pads the tail out to a
  /// whole 1024-frame AAC frame. `m4a` at least records the priming in its
  /// edit list; ADTS has no container metadata to declare it at all.
  ///
  /// A consumer reassembling rotated files losslessly wants this to be `true`.
  public var preservesExactFrameCount: Bool {
    switch self {
    case .wav, .aiff, .caf, .flac: true
    case .aac, .adts: false
    }
  }

  public var maximumRecordingChannelCount: Int {
    switch self {
    case .aac, .adts, .flac:
      8
    case .wav, .caf, .aiff:
      32
    }
  }

  public func supportsRecordingChannelCount(_ channelCount: Int) -> Bool {
    channelCount > 0 && channelCount <= maximumRecordingChannelCount
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
      return sampleRate >= 8000 && sampleRate <= 192_000
    case .flac:
      return sampleRate >= 8000 && sampleRate <= 655_350
    }
  }

  public func supports(sampleRate: SampleRate) -> Bool {
    supportsEncodedSampleRate(sampleRate.hz)
  }

  public var compatibleCommonSampleRates: [SampleRate] {
    SampleRate.common.filter { supports(sampleRate: $0) }
  }

  /// The encodable rate nearest to `sampleRate`.
  ///
  /// Used to resolve a ``RecordingSampleRate/hardware`` request against a
  /// route whose rate this format cannot encode — the AAC family tops out at
  /// 48 kHz, so a 96 kHz interface resolves to 48 kHz. Rates the format
  /// already supports return unchanged.
  public func nearestSupportedSampleRate(to sampleRate: SampleRate) -> SampleRate {
    guard !supports(sampleRate: sampleRate) else { return sampleRate }
    switch self {
    case .aac, .adts:
      let nearest = Self.aacCompatibleSampleRates.min {
        abs($0 - sampleRate.hz) < abs($1 - sampleRate.hz)
      }
      return SampleRate(nearest ?? 48_000)
    case .wav, .caf, .aiff:
      return SampleRate(min(max(sampleRate.hz, 8000), 192_000))
    case .flac:
      return SampleRate(min(max(sampleRate.hz, 8000), 655_350))
    }
  }

  package func recordingChannelLayout(
    for channelCount: Int,
  ) -> AVAudioChannelLayout? {
    guard supportsRecordingChannelCount(channelCount) else { return nil }
    let tag: AudioChannelLayoutTag
    switch self {
    case .aac, .adts:
      switch channelCount {
      case 1: tag = kAudioChannelLayoutTag_Mono
      case 2: tag = kAudioChannelLayoutTag_Stereo
      case 3: tag = kAudioChannelLayoutTag_AAC_3_0
      case 4: tag = kAudioChannelLayoutTag_AAC_Quadraphonic
      case 5: tag = kAudioChannelLayoutTag_AAC_5_0
      case 6: tag = kAudioChannelLayoutTag_AAC_5_1
      case 7: tag = kAudioChannelLayoutTag_AAC_6_1
      case 8: tag = kAudioChannelLayoutTag_AAC_7_1
      default: return nil
      }
    case .flac, .wav, .caf, .aiff:
      switch channelCount {
      case 1: tag = kAudioChannelLayoutTag_Mono
      case 2: tag = kAudioChannelLayoutTag_Stereo
      default:
        tag =
          AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder)
          | AudioChannelLayoutTag(channelCount)
      }
    }
    return AVAudioChannelLayout(layoutTag: tag)
  }

  package func recordingChannelLayoutData(
    for channelCount: Int,
  ) -> Data? {
    guard let layout = recordingChannelLayout(for: channelCount) else { return nil }
    return unsafe Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size)
  }
}
