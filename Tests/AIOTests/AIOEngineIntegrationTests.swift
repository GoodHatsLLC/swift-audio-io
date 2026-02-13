#if canImport(UIKit)
  import AVFoundation
  import Dispatch
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
    func testTapHandlerCanRunOffMainQueue() throws {
      let engine = AIOEngine()
      let processingFormat = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 48_000,
          channels: 1
        )
      )
      let tapHandler = engine.makeTapHandlerForTesting(processingFormat: processingFormat)
      let buffer = try #require(
        AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: 64
        )
      )
      buffer.frameLength = 64
      let time = AVAudioTime(sampleTime: 0, atRate: processingFormat.sampleRate)

      let queue = DispatchQueue(label: "AIOEngine.tap-handler-regression")
      queue.sync {
        tapHandler(buffer, time)
      }
    }

    @Test
    func testRotateRecordingFileEmitsTwoFiles() async throws {
      let engine = AIOEngine()
      let outputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIOEngineIntegrationTests-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: outputDirectory) }
      let configuration = makeConfiguration(outputDestination: .directory(outputDirectory))

      let firstURL = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: firstURL) }

      engine.injectTestAudio(channels: [ramp(count: 256)])
      let firstFileReady = await waitUntil(timeout: .seconds(1)) {
        fileHasBytes(at: firstURL)
      }
      try #require(firstFileReady == true)

      let rotatedURL = try await engine.rotateRecordingFile()
      defer { try? FileManager.default.removeItem(at: rotatedURL) }
      #expect(rotatedURL == firstURL)

      let rotatedOutputURL = try #require(
        await MainActor.run { engine.debugCurrentRecordingURL() }
      )
      #expect(rotatedOutputURL != firstURL)

      engine.injectTestAudio(channels: [ramp(count: 256)])
      let rotatedFileReady = await waitUntil(timeout: .seconds(1)) {
        fileHasBytes(at: rotatedOutputURL)
      }
      try #require(rotatedFileReady == true)
      let rotatedFramesWritten = await waitUntil(timeout: .seconds(1)) {
        await MainActor.run {
          engine.debugCurrentWriterWrittenSampleTime() >= 256
        }
      }
      try #require(rotatedFramesWritten == true)
      let finalURL = try await engine.stopRecording()
      defer { try? FileManager.default.removeItem(at: finalURL) }

      let rotatedSize = try #require(rotatedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
      let finalSize = try #require(finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
      #expect(finalURL != rotatedURL)
      #expect(rotatedSize > 0)
      #expect(finalSize > 0)
    }

    @Test
    func testStereoRecordingWritesFile() async throws {
      let engine = AIOEngine()
      let configuration = makeStereoConfiguration()

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      let left = (0..<480).map { Float($0) / 480.0 }
      let right = (0..<480).map { 1.0 - Float($0) / 480.0 }
      engine.injectTestAudio(channels: [left, right])

      let stoppedURL = try await engine.stopRecording()
      try #require(stoppedURL == url)

      let size = try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
      #expect(size > 0)

      let file = try AVAudioFile(forReading: url)
      #expect(file.fileFormat.channelCount == 2)
      #expect(file.length > 0)
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

    @Test
    func testFaultInjectionStopsRecordingWhenSampleRateBecomesUnsupported() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()
      let probe = RouteFaultProbe()

      await MainActor.run {
        engine.onRecordingInterruption = { interruption in
          await probe.record(interruption)
        }
        engine.onRecordingFailed = {
          Task { await probe.recordFailure() }
        }
      }

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      let oldFormat = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 48_000,
          channels: 1
        )
      )
      let unsupported = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 7_000,
          channels: oldFormat.channelCount
        )
      )

      let continued = await engine.simulateRouteChangeForTesting(
        oldFormat: oldFormat,
        newFormat: unsupported,
        processingFormat: oldFormat,
        isInputAvailable: true,
        reason: .routeConfigurationChange
      )

      #expect(continued == false)

      let stopped = await waitUntil(timeout: .seconds(1)) {
        await engine.isRecording == false
      }
      #expect(stopped == true)

      let snapshot = await probe.snapshot()
      #expect(snapshot.failureCount == 1)
      #expect(
        snapshot.interruptions.contains { interruption in
          if case .stoppedByInterruption(let reason) = interruption {
            return reason == "No suitable audio route available"
          }
          return false
        }
      )
    }

    @Test
    func testFaultInjectionStopsRecordingWhenInputBecomesUnavailable() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      let oldFormat = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 48_000,
          channels: 1
        )
      )
      let validNew = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 48_000,
          channels: oldFormat.channelCount
        )
      )

      let continued = await engine.simulateRouteChangeForTesting(
        oldFormat: oldFormat,
        newFormat: validNew,
        processingFormat: oldFormat,
        isInputAvailable: false,
        reason: .oldDeviceUnavailable
      )

      #expect(continued == false)
      #expect(await engine.isRecording == false)
    }

    @Test
    func testFaultInjectionContinuesRecordingAndEmitsQualityChange() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()
      let probe = RouteFaultProbe()

      await MainActor.run {
        engine.onRecordingInterruption = { interruption in
          await probe.record(interruption)
        }
      }

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      let oldFormat = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 48_000,
          channels: 1
        )
      )
      let changed = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 16_000,
          channels: 2
        )
      )

      let continued = await engine.simulateRouteChangeForTesting(
        oldFormat: oldFormat,
        newFormat: changed,
        processingFormat: oldFormat,
        isInputAvailable: true,
        reason: .newDeviceAvailable
      )

      #expect(continued == true)
      #expect(await engine.isRecording == true)

      let observed = await waitUntil(timeout: .seconds(1)) {
        let snapshot = await probe.snapshot()
        return snapshot.interruptions.isEmpty == false
      }
      #expect(observed == true)

      let snapshot = await probe.snapshot()
      #expect(
        snapshot.interruptions.contains { interruption in
          if case .routeChangeContinuing(_, let qualityChange) = interruption {
            guard let qualityChange else { return false }
            return qualityChange.currentChannels == 2
              && abs(qualityChange.currentSampleRate - 16_000) < 0.5
          }
          return false
        }
      )

      _ = try await engine.stopRecording()
    }


    @Test
    func testHandleRouteChangeReconfiguresTapWhenFormatAppearsUnchanged() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()
      let reconfigureCalls = LockedCounter()

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }
      defer {
        Task { @MainActor in
          engine.clearRouteChangeTestOverrides()
        }
      }

      let unchangedFormat = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 48_000,
          channels: 1
        )
      )
      await MainActor.run {
        engine.setRouteChangeTestOverrides(
          inputFormat: unchangedFormat,
          isInputAvailable: true,
          reconfigureTap: { _ in
            reconfigureCalls.increment()
          }
        )
      }

      let event = AudioRouteChangeEvent(
        reason: .routeConfigurationChange,
        previousRoute: nil,
        session: AVAudioSession.sharedInstance()
      )
      await engine.handleRouteChange(event: event)

      #expect(await engine.isRecording == true)
      #expect(reconfigureCalls.snapshot() == 1)

      _ = try await engine.stopRecording()
    }

    @Test
    func testHandleRouteChangeContinuesWhenTapReconfigureSucceeds() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()
      let probe = RouteFaultProbe()
      let reconfigureCalls = LockedCounter()

      await MainActor.run {
        engine.onRecordingInterruption = { interruption in
          await probe.record(interruption)
        }
      }

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }
      defer {
        Task { @MainActor in
          engine.clearRouteChangeTestOverrides()
        }
      }

      let routeFormat = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 16_000,
          channels: 2
        )
      )
      await MainActor.run {
        engine.setRouteChangeTestOverrides(
          inputFormat: routeFormat,
          isInputAvailable: true,
          reconfigureTap: { _ in
            reconfigureCalls.increment()
          }
        )
      }

      let event = AudioRouteChangeEvent(
        reason: .newDeviceAvailable,
        previousRoute: nil,
        session: AVAudioSession.sharedInstance()
      )
      await engine.handleRouteChange(event: event)

      #expect(await engine.isRecording == true)
      #expect(reconfigureCalls.snapshot() == 1)

      let observed = await waitUntil(timeout: .seconds(1)) {
        let snapshot = await probe.snapshot()
        return snapshot.interruptions.isEmpty == false
      }
      #expect(observed == true)
      let snapshot = await probe.snapshot()
      #expect(
        snapshot.interruptions.contains { interruption in
          if case .routeChangeContinuing(_, let qualityChange) = interruption {
            guard let qualityChange else { return false }
            return qualityChange.currentChannels == 2
              && abs(qualityChange.currentSampleRate - 16_000) < 0.5
          }
          return false
        }
      )

      _ = try await engine.stopRecording()
    }

    @Test
    func testHandleRouteChangeStopsWhenTapReconfigureFails() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()
      let probe = RouteFaultProbe()

      await MainActor.run {
        engine.onRecordingInterruption = { interruption in
          await probe.record(interruption)
        }
        engine.onRecordingFailed = {
          Task { await probe.recordFailure() }
        }
      }

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }
      defer {
        Task { @MainActor in
          engine.clearRouteChangeTestOverrides()
        }
      }

      let routeFormat = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 16_000,
          channels: 1
        )
      )
      await MainActor.run {
        engine.setRouteChangeTestOverrides(
          inputFormat: routeFormat,
          isInputAvailable: true,
          reconfigureTap: { (_: AVAudioFormat) throws(AIOEngine.AIOError) in
            throw .engineError
          }
        )
      }

      let event = AudioRouteChangeEvent(
        reason: .routeConfigurationChange,
        previousRoute: nil,
        session: AVAudioSession.sharedInstance()
      )
      await engine.handleRouteChange(event: event)

      let stopped = await waitUntil(timeout: .seconds(1)) {
        await engine.isRecording == false
      }
      #expect(stopped == true)

      let snapshot = await probe.snapshot()
      #expect(snapshot.failureCount == 1)
      #expect(
        snapshot.interruptions.contains { interruption in
          if case .stoppedByInterruption(let reason) = interruption {
            return reason == "Route change reconfiguration failed"
          }
          return false
        }
      )
    }

    private func makeConfiguration(
      outputDestination: RecordingConfiguration.OutputDestination = .temporary
    ) -> RecordingConfiguration {
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
        outputDestination: outputDestination
      )
    }

    private func makeStereoConfiguration() -> RecordingConfiguration {
      let input = InputConfiguration(
        sampleRate: SampleRate.common(.sr48000),
        channels: .stereo
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

    private func waitUntil(
      timeout: Duration,
      condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: timeout)
      while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
      }
      return await condition()
    }

    private func fileHasBytes(at url: URL) -> Bool {
      guard FileManager.default.fileExists(atPath: url.path) else { return false }
      do {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return (values.fileSize ?? 0) > 0
      } catch {
        return false
      }
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
      unsafe processBuffer(data, timing: BufferTiming(sampleTime: 0, sampleRate: 48_000))
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>, timing: BufferTiming) {
      lock.lock()
      storedValues = unsafe Array(data)
      storedTiming = timing
      lock.unlock()
    }

    nonisolated func endBufferTask() {}
  }

  private actor RouteFaultProbe {
    private(set) var interruptions: [AIOEngine.RecordingInterruption] = []
    private(set) var failureCount: Int = 0

    func record(_ interruption: AIOEngine.RecordingInterruption) {
      interruptions.append(interruption)
    }

    func recordFailure() {
      failureCount += 1
    }

    func snapshot() -> (interruptions: [AIOEngine.RecordingInterruption], failureCount: Int) {
      (interruptions, failureCount)
    }
  }

  private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0

    func increment() {
      lock.lock()
      value += 1
      lock.unlock()
    }

    func snapshot() -> Int {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }
#endif
