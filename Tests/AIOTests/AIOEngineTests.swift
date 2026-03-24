// © GoodHatsLLC

#if canImport(UIKit)
  import AVFoundation
  import Testing
  import UIKit
  import XCTest
  @testable import AIOAudioSession
  @testable import AIOEngine

  struct AIOEngineTests {
    @Test
    func `configuration creates format`() throws {
      let config = RecordingConfiguration(
        inputConfiguration: InputConfiguration(sampleRate: .common(.sr48000), channels: .stereo),
        outputConfiguration: .init(fileFormat: .aac, bitDepth: .pcmFloat32, quality: .high),
      )
      #expect(config.fileFormat?.sampleRate == 48000)
      try #require(config.fileFormat?.channelCount == 2)
    }

    @Test
    func `AAC rejects unsupported encoder sample rate`() throws {
      let config = RecordingConfiguration(
        inputConfiguration: InputConfiguration(sampleRate: .common(.sr96000), channels: .mono),
        outputConfiguration: .init(fileFormat: .aac, bitDepth: .pcmFloat32, quality: .high),
      )

      #expect(config.fileFormat == nil)
      #expect(config.fileSettings == nil)
    }

    @Test
    func `ADTS rejects unsupported encoder sample rate`() throws {
      let config = RecordingConfiguration(
        inputConfiguration: InputConfiguration(sampleRate: .common(.sr96000), channels: .mono),
        outputConfiguration: .init(fileFormat: .adts, bitDepth: .pcmFloat32, quality: .high),
      )

      #expect(config.fileFormat == nil)
      #expect(config.fileSettings == nil)
    }

    @Test
    func `AAC compatible common sample rate matrix`() {
      let expectedAACRates: [SampleRate] = [
        .common(.sr16000),
        .common(.sr22050),
        .common(.sr24000),
        .common(.sr44100),
        .common(.sr48000),
      ]
      #expect(FileFormat.aac.compatibleCommonSampleRates == expectedAACRates)
      #expect(FileFormat.adts.compatibleCommonSampleRates == expectedAACRates)
    }

    @Test
    func `PCM and FLAC support all common sample rates`() {
      let allCommonRates = SampleRate.commonCases
      #expect(FileFormat.wav.compatibleCommonSampleRates == allCommonRates)
      #expect(FileFormat.caf.compatibleCommonSampleRates == allCommonRates)
      #expect(FileFormat.aiff.compatibleCommonSampleRates == allCommonRates)
      #expect(FileFormat.flac.compatibleCommonSampleRates == allCommonRates)
    }

    @Test
    func `tap configuration preserves bus`() throws {
      let configuration = RecordingConfiguration(
        inputConfiguration: .init(
          sampleRate: .common(.sr48000),
          channels: .stereo,
        ),
        outputConfiguration: .init(
          fileFormat: .caf,
          bitDepth: .pcmFloat32,
          quality: .maximum,
        ),
      )

      let inputFormat = try #require(
        AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: 48000,
          channels: 2,
          interleaved: false,
        ),
      )

      let tapConfiguration = configuration.tapConfiguration(
        bus: 1,
        input: inputFormat,
      )

      try #require(tapConfiguration?.bus == 1)
    }

    @Test
    func `source change detection logic`() throws {
      final class TestManager {
        var _availableSources: [Int]
        init(initial: [Int]) {
          _availableSources = initial
        }

        var availableSources: [Int] {
          _availableSources
        }

        func updateSources(to new: [Int]) -> (added: [Int], removed: [Int]) {
          let previous = Set(availableSources)
          _availableSources = new
          let current = Set(new)
          let added = current.subtracting(previous).sorted()
          let removed = previous.subtracting(current).sorted()
          return (Array(added), Array(removed))
        }
      }

      let mgr = TestManager(initial: [1, 2])
      let diff = mgr.updateSources(to: [2, 3])
      try #require(diff.added == [3])
      try #require(diff.removed == [1])
    }
  }
#endif
