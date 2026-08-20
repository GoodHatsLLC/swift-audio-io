// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import Foundation
  import Testing

  struct RecordingSampleRateTests {
    // NOTE: no parameterized tests (@Test(arguments:)) in this package — they
    // fail to compile on this toolchain. Loop inside a single test instead.

    @Test("Codable round-trips preserve every case")
    func codableRoundTrips() throws {
      let values: [RecordingSampleRate] = [
        .hardware, .exact(.cd), .exact(.dvd), .exact(SampleRate(16_000)),
      ]
      for value in values {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(RecordingSampleRate.self, from: data)
        #expect(decoded == value)
      }
    }

    @Test("Codable emits the documented keyed shape")
    func codableShape() throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]

      let hardware = try String(decoding: encoder.encode(RecordingSampleRate.hardware), as: UTF8.self)
      #expect(hardware == #"{"hardware":true}"#)

      let exact = try String(
        decoding: encoder.encode(RecordingSampleRate.exact(.dvd)), as: UTF8.self)
      #expect(exact == #"{"exact":{"hz":48000}}"#)
    }

    @Test("Decoding an empty or unknown container fails rather than defaulting")
    func decodingRejectsUnknownShapes() throws {
      for json in ["{}", #"{"hardware":false}"#, #"{"unknown":1}"#] {
        #expect(throws: (any Error).self) {
          try JSONDecoder().decode(RecordingSampleRate.self, from: Data(json.utf8))
        }
      }
    }

    @Test("exact accessor exposes the target only for .exact")
    func exactAccessor() {
      #expect(RecordingSampleRate.hardware.exact == nil)
      #expect(RecordingSampleRate.exact(.cd).exact == .cd)
    }

    @Test("CaptureFormat wraps an InputConfiguration as an exact request")
    func captureFormatFromInputConfiguration() {
      let configuration = InputConfiguration(sampleRate: .cd, channels: .stereo)
      let format = CaptureFormat(configuration)
      #expect(format.sampleRate == .exact(.cd))
      #expect(format.channels == .stereo)
      #expect(format.exactConfiguration == configuration)
      #expect(format.exactSampleRate == .cd)
    }

    @Test("CaptureFormat.hardware has no exact configuration until resolved")
    func captureFormatHardwareIsUnresolved() {
      let format = CaptureFormat(sampleRate: .hardware, channels: .mono)
      #expect(format.exactConfiguration == nil)
      #expect(format.exactSampleRate == nil)
    }

    @Test("resolved(hardwareSampleRate:) adopts hardware only for .hardware")
    func resolution() {
      let hardware = CaptureFormat(sampleRate: .hardware, channels: .mono)
      #expect(
        hardware.resolved(hardwareSampleRate: .dvd)
          == InputConfiguration(sampleRate: .dvd, channels: .mono))

      let exact = CaptureFormat(sampleRate: .exact(.cd), channels: .stereo)
      #expect(
        exact.resolved(hardwareSampleRate: .dvd)
          == InputConfiguration(sampleRate: .cd, channels: .stereo))
    }

    @Test("ResolvedCaptureFormat reports resampling and effective bandwidth")
    func resolvedCaptureFormat() {
      let native = ResolvedCaptureFormat(
        hardware: InputConfiguration(sampleRate: .dvd, channels: .mono),
        processing: InputConfiguration(sampleRate: .dvd, channels: .mono),
      )
      #expect(!native.isResampling)
      #expect(native.effectiveSampleRate == .dvd)

      // The HFP trap: a 16 kHz Bluetooth mic feeding a 48 kHz file. The file
      // says 48 kHz; the honest bandwidth ceiling is 16 kHz.
      let upsampled = ResolvedCaptureFormat(
        hardware: InputConfiguration(sampleRate: SampleRate(16_000), channels: .mono),
        processing: InputConfiguration(sampleRate: .dvd, channels: .mono),
      )
      #expect(upsampled.isResampling)
      #expect(upsampled.effectiveSampleRate == SampleRate(16_000))

      // Downsampling (48 kHz hardware into a 16 kHz speech file) is bounded by
      // the processing rate.
      let downsampled = ResolvedCaptureFormat(
        hardware: InputConfiguration(sampleRate: .dvd, channels: .mono),
        processing: InputConfiguration(sampleRate: SampleRate(16_000), channels: .mono),
      )
      #expect(downsampled.isResampling)
      #expect(downsampled.effectiveSampleRate == SampleRate(16_000))
    }
  }
#endif
