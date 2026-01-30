#if canImport(UIKit)
  import AVFoundation
  import Foundation
  import Testing
  import Tools

  @_spi(TESTING) import AIOEngine

  @Suite
  struct AIOEngineIntegrationTests {
    @Test
    func testTestRecordingWritesFile() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      let samples = (0..<480).map { Float($0) / 480.0 }
      engine.injectTestAudio(channels: [samples])

      let stoppedURL = try await engine.stopRecording()
      try #require(stoppedURL == url)

      let size = try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
      #expect(size > 0)
    }

    @Test
    func testTestRecordingDeliversReceiverBuffers() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()
      let receiver = CapturingReceiver()

      await engine.attachBufferReceiver(receiver)

      let url = try await engine.startTestRecording(
        configuration: configuration,
        enableReceivers: true
      )
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

      _ = try await engine.stopRecording()
    }

    @Test
    func testRotateRecordingFileEmitsTwoFiles() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()

      let firstURL = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: firstURL) }

      engine.injectTestAudio(channels: [ramp(count: 256)])

      let rotatedURL = try await engine.rotateRecordingFile()
      defer { try? FileManager.default.removeItem(at: rotatedURL) }
      #expect(rotatedURL == firstURL)

      engine.injectTestAudio(channels: [ramp(count: 256)])

      let finalURL = try await engine.stopRecording()
      defer { try? FileManager.default.removeItem(at: finalURL) }

      let rotatedSize = try #require(rotatedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
      let finalSize = try #require(finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
      #expect(finalURL != rotatedURL)
      #expect(rotatedSize > 0)
      #expect(finalSize > 0)
    }

    @Test
    func testInterruptionStopsRecording() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      engine.injectTestAudio(channels: [ramp(count: 256)])

      await engine.handleInterruption(type: .began, options: nil)

      let start = ContinuousClock.now
      while await engine.isRecording,
        ContinuousClock.now - start < .seconds(1)
      {
        try? await Task.sleep(for: .milliseconds(10))
      }

      let isRecording = await engine.isRecording
      #expect(isRecording == false)

      let size = try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
      #expect(size > 0)
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

    private func ramp(count: Int) -> [Float] {
      guard count > 0 else { return [] }
      return (0..<count).map { Float($0) / Float(count) }
    }
  }

  private final class CapturingReceiver: BufferReceiver, @unchecked Sendable {
    typealias T = Float
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
