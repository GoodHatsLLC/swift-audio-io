#if canImport(AVFoundation)
  import AVFoundation
  import Testing
  import UIKit
  import XCTest

  @testable import AIOEngine

  @Suite
  struct AIOEngineTests {
    @Test
    func testConfigurationCreatesFormat() throws {
      let config = RecordingConfiguration(
        inputConfiguration: InputConfiguration(sampleRate: .common(.sr48000), channels: .stereo),
        outputConfiguration: .init(fileFormat: .aac, bitDepth: .pcmFloat32, quality: .high)
      )
      #expect(config.fileFormat?.sampleRate == 48_000)
      try #require(config.fileFormat?.channelCount == 2)
    }

    @Test
    func testTapConfigurationPreservesBus() throws {
      let configuration = RecordingConfiguration(
        inputConfiguration: .init(
          sampleRate: .common(.sr48000),
          channels: .stereo
        ),
        outputConfiguration: .init(
          fileFormat: .caf,
          bitDepth: .pcmFloat32,
          quality: .maximum
        )
      )

      let inputFormat = try #require(
        AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: 48_000,
          channels: 2,
          interleaved: false
        )
      )

      let tapConfiguration = configuration.tapConfiguration(
        bus: 1,
        input: inputFormat
      )

      try #require(tapConfiguration?.bus == 1)
    }

    @Test
    func testSourceChangeDetectionLogic() throws {
      final class TestManager {
        var _availableSources: [Int]
        init(initial: [Int]) { self._availableSources = initial }
        var availableSources: [Int] { _availableSources }
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
