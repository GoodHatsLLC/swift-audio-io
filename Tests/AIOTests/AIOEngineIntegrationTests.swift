#if canImport(UIKit)
  import AVFoundation
  import Foundation
  import Testing

  @_spi(TESTING) import AIOEngine

  @Suite
  struct AIOEngineIntegrationTests {
    @Test
    func testTestRecordingWritesFile() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()

      let url = try await MainActor.run {
        try engine.startTestRecording(configuration: configuration)
      }
      defer { try? FileManager.default.removeItem(at: url) }

      let samples = (0..<480).map { Float($0) / 480.0 }
      engine.injectTestAudio(channels: [samples])

      let stoppedURL = try await MainActor.run {
        try engine.stopRecording()
      }
      try #require(stoppedURL == url)

      let size = try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
      #expect(size > 0)
    }

    @Test
    func testTestRecordingDeliversReceiverBuffers() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()
      let receiver = CapturingReceiver()

      engine.attachBufferReceiver(receiver)

      let url = try await MainActor.run {
        try engine.startTestRecording(configuration: configuration, enableReceivers: true)
      }
      defer { try? FileManager.default.removeItem(at: url) }

      let samples = (0..<128).map { Float($0) / 128.0 }
      engine.injectTestAudio(channels: [samples])

      let start = ContinuousClock.now
      while receiver.snapshot().values.isEmpty,
        ContinuousClock.now - start < .seconds(1)
      {
        try? await Task.sleep(for: .milliseconds(10))
      }

      let snapshot = receiver.snapshot()
      #expect(snapshot.values == samples)
      #expect(snapshot.timing?.sampleTime == 0)

      _ = try await MainActor.run { try engine.stopRecording() }
    }

    private func makeConfiguration() -> RecordingConfiguration {
      let input = InputConfiguration(
        sampleRate: SampleRate.common(.sr48000),
        channels: .mono
      )
      let output = OutputConfiguration(
        fileFormat: .caf,
        bitDepth: .pcmFloat32,
        quality: .high
      )
      return RecordingConfiguration(
        inputConfiguration: input,
        outputConfiguration: output,
        outputDestination: .temporary
      )
    }
  }

  private final class CapturingReceiver: BufferReceiver<Float>, @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Float] = []
    private var storedTiming: BufferTiming?

    func snapshot() -> (values: [Float], timing: BufferTiming?) {
      lock.lock()
      defer { lock.unlock() }
      return (storedValues, storedTiming)
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>) {
      processBuffer(data, timing: BufferTiming(sampleTime: 0, sampleRate: 48_000))
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>, timing: BufferTiming) {
      lock.lock()
      storedValues = Array(data)
      storedTiming = timing
      lock.unlock()
    }

    nonisolated func endBufferTask() {}
  }
#endif
