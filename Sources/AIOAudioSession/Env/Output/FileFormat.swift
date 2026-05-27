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
    case .aac, .adts: true
    case .wav, .caf, .flac, .aiff: false
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
