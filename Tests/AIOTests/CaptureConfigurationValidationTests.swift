// © GoodHatsLLC

#if canImport(AVFoundation)
  import AVFoundation
  import Testing
  @_spi(AVFoundation) @testable import AIOAudioSession
  @testable import AudioIO

  /// The capture format and the output encoding are chosen through independent
  /// APIs, so nothing but an explicit check catches a combination that is
  /// individually reasonable on both sides and jointly impossible.
  ///
  /// Every assertion here is side-effect free: no audio session, no route, no
  /// activation. That is the property being pinned, not an incidental one — a
  /// caller has to be able to grey out a picker entry before touching the
  /// microphone.
  ///
  /// The suite loops over formats rather than using `@Test(arguments:)`: that
  /// macro's expansion does not compile on this toolchain, which is why the
  /// package has no parameterized tests.
  struct CaptureConfigurationValidationTests {
    private static let aacFamily: [FileFormat] = [.aac, .adts]
    private static let bitDepthKeys = [AVLinearPCMBitDepthKey, AVEncoderBitDepthHintKey]

    /// The headline case: AAC tops out at 48 kHz, so a high-resolution capture
    /// cannot be encoded to `m4a` or `aac` at all.
    @Test
    func `AAC rejects high-resolution sample rates`() throws {
      for fileFormat in Self.aacFamily {
        for sampleRate in [SampleRate.hiRes96, .hiRes192] {
          let output = OutputConfiguration(fileFormat: fileFormat, bitDepth: nil, quality: .high)
          let input = InputConfiguration(sampleRate: sampleRate, channels: .mono)

          let validation = output.validate(against: input)

          #expect(
            validation.isValid == false,
            "\(fileFormat.description) accepted \(sampleRate).",
          )
          #expect(
            validation.issues.contains(
              .unsupportedSampleRate(
                sampleRate,
                fileFormat: fileFormat,
                supported: fileFormat.compatibleCommonSampleRates,
              ),
            ),
          )

          // The same verdict is reachable from the whole capture
          // configuration, and it names the reason the writer would refuse.
          let configuration = RecordingConfiguration(
            inputConfiguration: input,
            outputConfiguration: output,
          )
          #expect(configuration.validate().isValid == false)
          #expect(configuration.fileSettings == nil)
        }
      }
    }

    @Test
    func `lossless formats accept high-resolution sample rates`() {
      for fileFormat in [FileFormat.wav, .caf, .aiff, .flac] {
        let output = OutputConfiguration(
          fileFormat: fileFormat,
          bitDepth: fileFormat.defaultBitDepth,
          quality: .maximum,
        )

        #expect(
          output.validate(
            against: InputConfiguration(sampleRate: .hiRes96, channels: .stereo),
          ).isValid,
          "\(fileFormat.description) rejected 96 kHz.",
        )
      }
    }

    @Test
    func `a channel count beyond the format ceiling is rejected`() {
      let output = OutputConfiguration(fileFormat: .adts, bitDepth: nil, quality: .high)
      let input = InputConfiguration(
        sampleRate: .dvd,
        channels: ChannelCount(platform: 16),
      )

      let validation = output.validate(against: input)

      #expect(
        validation.issues == [
          .unsupportedChannelCount(16, fileFormat: .adts, maximum: 8)
        ],
      )
    }

    // MARK: - Capabilities describe the writer

    /// The bit-depth capability has to describe what the writer actually keys
    /// on. It used to claim AAC supported Float32 and Int16, neither of which
    /// reaches an AAC file.
    @Test
    func `the bit-depth capability matches what the writer uses`() throws {
      for fileFormat in FileFormat.allCases where !fileFormat.usesBitDepth {
        let settings = try #require(
          makeConfiguration(fileFormat: fileFormat, bitDepth: nil).fileSettings,
        )
        for key in Self.bitDepthKeys {
          #expect(
            settings[key] == nil,
            "\(fileFormat.description) claims no bit depth but its settings carry \(key).",
          )
        }
        // And the API refuses to let a caller pretend otherwise.
        for bitDepth in BitDepth.allCases {
          let output = OutputConfiguration(
            fileFormat: fileFormat, bitDepth: bitDepth, quality: .high,
          )
          #expect(
            output.isSupported == false,
            "\(fileFormat.description) accepted a meaningless \(bitDepth).",
          )
        }
      }

      for fileFormat in FileFormat.allCases where fileFormat.usesBitDepth {
        // A format that claims to use bit depth must key on it, and each
        // claimed depth must reach the file as a distinct value.
        var writtenDepths: Set<Int> = []
        for bitDepth in fileFormat.supportedBitDepths {
          let settings = try #require(
            makeConfiguration(fileFormat: fileFormat, bitDepth: bitDepth).fileSettings,
            "\(fileFormat.description) rejected its own supported \(bitDepth).",
          )
          let written = try #require(
            Self.bitDepthKeys.compactMap { settings[$0] as? Int }.first,
            "\(fileFormat.description) claims to use bit depth but keys on none.",
          )
          writtenDepths.insert(written)
        }
        #expect(
          writtenDepths.count == fileFormat.supportedBitDepths.count,
          "\(fileFormat.description) collapsed distinct bit depths onto \(writtenDepths).",
        )

        // Omitting a required depth is an issue, not a silent default.
        let missing = OutputConfiguration(fileFormat: fileFormat, bitDepth: nil, quality: .high)
        #expect(missing.isSupported == false)
      }
    }

    /// The encoding-quality capability has to describe what the writer actually
    /// keys on. `EncodingQuality` is an `AVAudioQuality` level, not a bitrate,
    /// and it only reaches lossy formats.
    @Test
    func `the encoding-quality capability matches what the writer uses`() throws {
      for fileFormat in FileFormat.allCases {
        let settings = try #require(
          makeConfiguration(
            fileFormat: fileFormat,
            bitDepth: fileFormat.defaultBitDepth,
            quality: .low,
          ).fileSettings,
        )
        let quality = settings[AVEncoderAudioQualityKey] as? Int

        if fileFormat.usesEncodingQuality {
          #expect(
            quality == Int(EncodingQuality.low.avAudio.rawValue),
            "\(fileFormat.description) claims to use quality but did not write it.",
          )
          // It is a quality *level*: AudioIO never emits a bitrate key, so two
          // recordings at the same level are not promised the same bitrate.
          #expect(settings[AVEncoderBitRateKey] == nil)
        } else {
          #expect(
            quality == nil,
            """
            \(fileFormat.description) claims to ignore quality but wrote \
            \(String(describing: quality)).
            """,
          )
        }
      }
    }

    @Test
    func `the AAC family reports no selectable bit depth`() {
      for fileFormat in Self.aacFamily {
        #expect(fileFormat.supportedBitDepths.isEmpty)
        #expect(fileFormat.usesBitDepth == false)
        #expect(fileFormat.defaultBitDepth == nil)
        #expect(fileFormat.usesEncodingQuality)
      }
    }

    // MARK: - Helpers

    private func makeConfiguration(
      fileFormat: FileFormat,
      bitDepth: BitDepth?,
      quality: EncodingQuality = .high,
    ) -> RecordingConfiguration {
      RecordingConfiguration(
        // 48 kHz mono is encodable by every format, so the only variable is the
        // encoding choice under test.
        inputConfiguration: InputConfiguration(sampleRate: .dvd, channels: .mono),
        outputConfiguration: OutputConfiguration(
          fileFormat: fileFormat,
          bitDepth: bitDepth,
          quality: quality,
        ),
      )
    }
  }
#endif
