// © GoodHatsLLC

#if canImport(AVFoundation)
  import AVFoundation
  import Testing

  /// The OS 27 `installAudioTap` provider hands out `AVReadOnlyAudioPCMBuffer`;
  /// the capture path bridges it back into `AVAudioPCMBuffer(copying:)`. This
  /// verifies the round-trip preserves format, length, and samples — the
  /// contract the tap bridge in `AIOEngine+TapSetup` relies on.
  ///
  /// Compiles only under the Xcode 27 SDK and runs only on OS 27 hosts; the
  /// CI toolchain (Xcode 26.5 on macOS 26) skips it entirely, which is exactly
  /// the coverage split the tap install itself has.
  struct ReadOnlyBufferBridgeTests {
    @Test
    func `read-only buffer round-trip preserves format and samples`() throws {
      #if compiler(>=6.4)
        guard #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) else { return }

        let format = try #require(
          AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
        )
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        source.frameLength = 256
        let channel = try #require(source.floatChannelData?[0])
        for frame in 0..<256 {
          unsafe channel[frame] = Float(frame) / 256
        }

        let readOnly = AVReadOnlyAudioPCMBuffer(copying: source)
        #expect(readOnly.frameLength == 256)
        #expect(readOnly.format == format)

        let bridged = AVAudioPCMBuffer(copying: readOnly)
        #expect(bridged.frameLength == 256)
        #expect(bridged.format == format)
        let bridgedChannel = try #require(bridged.floatChannelData?[0])
        for frame in 0..<256 {
          #expect(unsafe bridgedChannel[frame] == Float(frame) / 256)
        }
      #endif
    }
  }
#endif
