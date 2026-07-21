// © GoodHatsLLC

#if canImport(UIKit)
  import AVFoundation
  import Dispatch
  import Foundation
  import Testing
  import Tools

  @testable import AIOAudioSession
  @_spi(TESTING) @testable import AudioIO
  @testable import AIORecording
  @testable import AIORecordingSupport

  @Suite(.serialized)
  struct AIOEngineIntegrationTests {
    @Test
    func `recording writes file`() async throws {
      let engine = AIOEngine()
      await engine.debugBypassEngineTeardownForTesting()
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
    func `recording delivers receiver buffers`() async throws {
      let engine = AIOEngine()
      await engine.debugBypassEngineTeardownForTesting()
      let configuration = makeConfiguration()
      let receiver = CapturingReceiver()

      let receiverToken = await engine.attachBufferReceiver(receiver)
      defer { receiverToken.invalidate() }

      let url = try await engine.startTestRecording(
        configuration: configuration,
        enableReceivers: true,
      )
      defer { try? FileManager.default.removeItem(at: url) }

      let samples = (0..<128).map { Float($0) / 128.0 }
      engine.injectTestAudio(channels: [samples])

      #expect(await receiver.waitUntilReceived() == true)

      let snapshot = receiver.snapshot()
      #expect(snapshot.values == samples)
      #expect(snapshot.timing?.sampleTime == 0)

      _ = try await engine.stopRecording()
    }

    @Test
    func `tap handler can run off main queue`() throws {
      let engine = AIOEngine()
      let processingFormat = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 48000,
          channels: 1,
        ),
      )
      let tapHandler = engine.makeTapHandlerForTesting(processingFormat: processingFormat)
      let buffer = try #require(
        AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: 64,
        ),
      )
      buffer.frameLength = 64
      let time = AVAudioTime(sampleTime: 0, atRate: processingFormat.sampleRate)

      let queue = DispatchQueue(label: "AIOEngine.tap-handler-regression")
      queue.sync {
        tapHandler(buffer, time)
      }
    }

    @Test
    func `rotate recording file emits two files`() async throws {
      let engine = AIOEngine()
      await engine.debugBypassEngineTeardownForTesting()
      let outputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "AIOEngineIntegrationTests-\(UUID().uuidString)", isDirectory: true,
        )
      defer { try? FileManager.default.removeItem(at: outputDirectory) }
      let configuration = makeConfiguration(outputDestination: .directory(outputDirectory))

      let firstURL = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: firstURL) }

      engine.injectTestAudio(channels: [ramp(count: 256)])

      let rotatedURL = try await engine.rotateRecordingFile()
      defer { try? FileManager.default.removeItem(at: rotatedURL) }
      #expect(rotatedURL == firstURL)

      let rotatedOutputURL = try #require(
        await MainActor.run { engine.debugCurrentRecordingURL() },
      )
      #expect(rotatedOutputURL != firstURL)

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
    func `queued writer drain stays in draining queue until drain task completes`()
      async throws
    {
      let engine = AIOEngine()
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("queued-writer-drain-\(UUID().uuidString).caf")

      let handle = await MainActor.run {
        engine.debugStartQueuedWriterDrainForTesting(
          fileURL: url,
          targetSampleTime: 256,
          writtenSampleTime: 0,
        )
      }

      let queuedIDs = await MainActor.run {
        engine.debugDrainingWriterSessionIDsForTesting()
      }
      #expect(queuedIDs == [handle.id])
      #expect(handle.stopRequested == true)
      #expect(handle.targetSampleTime == 256)
      #expect(handle.closeCount() == 0)

      await handle.signalDrain()
      await handle.waitUntilClosed()
      await engine.debugDrainRecordingCallbacksForTesting()

      let removedFromQueue = await MainActor.run {
        !engine.debugDrainingWriterSessionIDsForTesting().contains(handle.id)
      }
      #expect(removedFromQueue == true)
      #expect(handle.closeCount() == 1)
    }

    @Test
    func `queued writer drain completes when target sample time is already written`()
      async throws
    {
      let engine = AIOEngine()
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("target-satisfied-writer-drain-\(UUID().uuidString).caf")

      let handle = await MainActor.run {
        engine.debugStartQueuedWriterDrainForTesting(
          fileURL: url,
          targetSampleTime: 128,
          writtenSampleTime: 128,
        )
      }

      #expect(handle.stopRequested == true)
      #expect(handle.targetSampleTime == 128)
      #expect(handle.writtenSampleTime == 128)

      await handle.waitUntilClosed()
      await engine.debugDrainRecordingCallbacksForTesting()

      let removedFromQueue = await MainActor.run {
        !engine.debugDrainingWriterSessionIDsForTesting().contains(handle.id)
      }
      #expect(removedFromQueue == true)
      #expect(handle.closeCount() == 1)
    }

    @Test
    func `stereo recording writes file`() async throws {
      let engine = AIOEngine()
      await engine.debugBypassEngineTeardownForTesting()
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
    @MainActor
    func `unsupported recording channel count fails before tap install`() async throws {
      let engine = AIOEngine()
      engine.debugBypassEngineTeardownForTesting()
      // 33 exceeds the runtime cap (`currentMaximumRecordingChannelCount` == 32,
      // and .caf's per-format cap is also 32), so capacity validation rejects it
      // before the tap is installed.
      let configuration = makeConfiguration(channels: .init(platform: 33))
      var tapInstallAttempted = false

      engine.setReinstallTapOverride { _, _ throws(RecordingError) in
        tapInstallAttempted = true
        throw RecordingError.engineError
      }
      defer { engine.setReinstallTapOverride(nil) }

      let didStart = await engine.startRecordingWithReconciliation(configuration: configuration)

      #expect(didStart == false)
      #expect(tapInstallAttempted == false)

      switch engine.consumeLastRecordingStartFailure() {
      case .unsupportedChannelCount(let requested, let maximum):
        #expect(requested == 33)
        #expect(maximum == 32)
      case let other:
        Issue.record("Expected unsupportedChannelCount, got \(String(describing: other))")
      }
    }

    @Test
    func `interruption stops recording`() async throws {
      let engine = AIOEngine()
      let configuration = makeConfiguration()

      // Bypass the real AVAudioEngine teardown, which crashes the iOS Simulator
      // audio HAL; the writer drain and stop transitions still run.
      await engine.debugBypassEngineTeardownForTesting()

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      engine.injectTestAudio(channels: [ramp(count: 256)])

      await engine.handleInterruption(type: .began, options: nil)

      let isRecording = await engine.isRecording
      #expect(isRecording == false)

      let size = try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
      #expect(size > 0)
    }

    @Test
    func `fault injection stops recording when sample rate becomes unsupported`() async throws {
      let engine = AIOEngine()
      await engine.debugBypassEngineTeardownForTesting()
      let configuration = makeConfiguration()
      let probe = RouteFaultProbe()
      let bridge = await probe.bridge(to: engine)
      defer { bridge.cancelNow() }

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      let oldFormat = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 48000,
          channels: 1,
        ),
      )
      let unsupported = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 7000,
          channels: oldFormat.channelCount,
        ),
      )

      let continued = await engine.simulateRouteChangeForTesting(
        oldFormat: oldFormat,
        newFormat: unsupported,
        processingFormat: oldFormat,
        isInputAvailable: true,
        reason: .routeConfigurationChange,
      )

      #expect(continued == false)

      #expect(await engine.isRecording == false)

      let captured = await waitUntil(timeout: .seconds(2)) {
        let snapshot = probe.snapshot()
        return snapshot.failureCount == 1
          && snapshot.interruptions.contains { interruption in
            if case .stoppedByInterruption(let reason) = interruption {
              return reason == "No suitable audio route available"
            }
            return false
          }
      }
      #expect(captured == true)
      await bridge.cancel()
    }

    @Test
    func `fault injection stops recording when input becomes unavailable`() async throws {
      let engine = AIOEngine()
      await engine.debugBypassEngineTeardownForTesting()
      let configuration = makeConfiguration()

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      let oldFormat = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 48000,
          channels: 1,
        ),
      )
      let validNew = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 48000,
          channels: oldFormat.channelCount,
        ),
      )

      let continued = await engine.simulateRouteChangeForTesting(
        oldFormat: oldFormat,
        newFormat: validNew,
        processingFormat: oldFormat,
        isInputAvailable: false,
        reason: .oldDeviceUnavailable,
      )

      #expect(continued == false)
      #expect(await engine.isRecording == false)
    }

    @Test
    func `fault injection continues recording and emits quality change`() async throws {
      let engine = AIOEngine()
      await engine.debugBypassEngineTeardownForTesting()
      let configuration = makeConfiguration()
      let probe = RouteFaultProbe()
      let bridge = await probe.bridge(to: engine)
      defer { bridge.cancelNow() }

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      let oldFormat = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 48000,
          channels: 1,
        ),
      )
      let changed = try #require(
        AVAudioFormat(
          standardFormatWithSampleRate: 16000,
          channels: 2,
        ),
      )

      let continued = await engine.simulateRouteChangeForTesting(
        oldFormat: oldFormat,
        newFormat: changed,
        processingFormat: oldFormat,
        isInputAvailable: true,
        reason: .newDeviceAvailable,
      )

      #expect(continued == true)
      #expect(await engine.isRecording == true)

      let captured = await waitUntil(timeout: .seconds(2)) {
        probe.snapshot().interruptions.contains { interruption in
          if case .routeChangeContinuing(_, let qualityChange) = interruption {
            guard let qualityChange else { return false }
            return qualityChange.currentChannels == 2
              && abs(qualityChange.currentSampleRate - 16000) < 0.5
          }
          return false
        }
      }
      #expect(captured == true)

      _ = try await engine.stopRecording()
      await bridge.cancel()
    }

    @Test
    func `handle route change reconfigures tap when format appears unchanged`() async throws {
      let engine = AIOEngine()
      await engine.debugBypassEngineTeardownForTesting()
      let configuration = makeConfiguration()
      let reinstallCalls = LockedCounter()

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      let unchangedFormat = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
      )

      await MainActor.run {
        engine.setReinstallTapOverride {
          _, processingFormat throws(RecordingError) in
          reinstallCalls.increment()
          return try makeMockTapInstallResult(
            tapFormat: unchangedFormat, processingFormat: processingFormat,
          )
        }
      }

      let event = AudioRouteChangeEvent(
        reason: .routeConfigurationChange,
        previousRoute: nil,
        currentRoute: .init(inputs: [], outputs: []),
        session: makeSessionSnapshot(),
      )
      await engine.handleRouteChange(event: event)

      #expect(await engine.isRecording == true)
      #expect(reinstallCalls.snapshot() == 1)
      await MainActor.run {
        engine.setReinstallTapOverride(nil)
      }

      _ = try await engine.stopRecording()
    }

    @Test
    func `handle route change continues when tap reconfigure succeeds`() async throws {
      let engine = AIOEngine()
      await engine.debugBypassEngineTeardownForTesting()
      let configuration = makeConfiguration()
      let probe = RouteFaultProbe()
      let reinstallCalls = LockedCounter()
      let bridge = await probe.bridge(to: engine)
      defer { bridge.cancelNow() }

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      let routeFormat = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2),
      )

      await MainActor.run {
        engine.setReinstallTapOverride {
          _, processingFormat throws(RecordingError) in
          reinstallCalls.increment()
          return try makeMockTapInstallResult(
            tapFormat: routeFormat, processingFormat: processingFormat,
          )
        }
      }

      let event = AudioRouteChangeEvent(
        reason: .newDeviceAvailable,
        previousRoute: nil,
        currentRoute: .init(inputs: [], outputs: []),
        session: makeSessionSnapshot(),
      )
      await engine.handleRouteChange(event: event)

      #expect(await engine.isRecording == true)
      #expect(reinstallCalls.snapshot() == 1)
      await MainActor.run {
        engine.setReinstallTapOverride(nil)
      }

      let captured = await waitUntil(timeout: .seconds(2)) {
        probe.snapshot().interruptions.contains { interruption in
          if case .routeChangeContinuing(_, let qualityChange) = interruption {
            guard let qualityChange else { return false }
            return qualityChange.currentChannels == 2
              && abs(qualityChange.currentSampleRate - 16000) < 0.5
          }
          return false
        }
      }
      #expect(captured == true)

      _ = try await engine.stopRecording()
      await bridge.cancel()
    }

    @Test
    func `handle route change stops when tap reconfigure fails`() async throws {
      let engine = AIOEngine()
      await engine.debugBypassEngineTeardownForTesting()
      let configuration = makeConfiguration()
      let probe = RouteFaultProbe()
      let bridge = await probe.bridge(to: engine)
      defer { bridge.cancelNow() }

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      await MainActor.run {
        engine.setReinstallTapOverride {
          (
            _: RecordingConfiguration, _: AVAudioFormat,
          ) throws(RecordingError) -> TapInstallResult in
          throw .engineError
        }
      }

      let event = AudioRouteChangeEvent(
        reason: .routeConfigurationChange,
        previousRoute: nil,
        currentRoute: .init(inputs: [], outputs: []),
        session: makeSessionSnapshot(),
      )
      await engine.handleRouteChange(event: event)
      await MainActor.run {
        engine.setReinstallTapOverride(nil)
      }

      #expect(await engine.isRecording == false)

      let captured = await waitUntil(timeout: .seconds(2)) {
        let snapshot = probe.snapshot()
        return snapshot.failureCount == 1
          && snapshot.interruptions.contains { interruption in
            if case .stoppedByInterruption(let reason) = interruption {
              return reason == "Route change reconfiguration failed"
            }
            return false
          }
      }
      #expect(captured == true)
      await bridge.cancel()
    }

    /// Chunk 0 regression: a route-change tap reinstall that reaches the engine
    /// control queue *after* a teardown raised the `engineTearingDown` sentinel
    /// must bail on the queue — leaving no tap installed and emitting no
    /// `routeChangeContinuing` event — instead of reinstalling a live tap onto a
    /// graph the stop is tearing down.
    @Test
    func `route change reinstall bails when engine is tearing down`() async throws {
      let engine = AIOEngine()
      await engine.debugBypassEngineTeardownForTesting()
      let configuration = makeConfiguration()
      let probe = RouteFaultProbe()
      let bridge = await probe.bridge(to: engine)
      defer { bridge.cancelNow() }

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }

      // No tap is installed by `startTestRecording`; a successful reinstall would
      // set `installedTapBus`. Confirm the precondition.
      #expect(await engine.debugInstalledTapBusForTesting() == nil)

      // Simulate a teardown that has raised the sentinel (as `gracefulStop()` /
      // `hardStop()` do) before its on-queue work cleared state.
      await MainActor.run { engine.debugSetEngineTearingDownForTesting(true) }

      // An override that WOULD reinstall (and resurrect `installedTapBus`) unless
      // the on-queue teardown guard bails first.
      let routeFormat = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2),
      )
      await MainActor.run {
        engine.setReinstallTapOverride { _, processingFormat throws(RecordingError) in
          try makeMockTapInstallResult(
            tapFormat: routeFormat, processingFormat: processingFormat,
          )
        }
      }

      let event = AudioRouteChangeEvent(
        reason: .newDeviceAvailable,
        previousRoute: nil,
        currentRoute: .init(inputs: [], outputs: []),
        session: makeSessionSnapshot(),
      )
      await engine.handleRouteChange(event: event)

      await MainActor.run { engine.setReinstallTapOverride(nil) }

      // The reinstall bailed on the queue: no tap installed, recording still
      // active (the stop that raised the sentinel owns teardown), and no
      // `routeChangeContinuing` event was emitted.
      #expect(await engine.debugInstalledTapBusForTesting() == nil)
      #expect(await engine.isRecording == true)
      let sawContinuing = await waitUntil(timeout: .milliseconds(300)) {
        probe.snapshot().interruptions.contains { interruption in
          if case .routeChangeContinuing = interruption { return true }
          return false
        }
      }
      #expect(sawContinuing == false)
      await bridge.cancel()

      // Clearing the sentinel restores normal reinstall behaviour.
      await MainActor.run { engine.debugSetEngineTearingDownForTesting(false) }
      _ = try? await engine.stopRecording()
    }

    /// Chunk 1 regression: `rotateRecordingFile` hoists its file open off the
    /// main thread, introducing an `await`. A stop that raised the
    /// `engineTearingDown` sentinel (but has not yet flipped `isRecording`,
    /// because gracefulStop does that late) must NOT let rotate swap a fresh
    /// writer/loop into a stopped recording — it must bail like the reinstall
    /// callers. The post-await guard checks `!engineTearingDown`, not just
    /// `isRecording`.
    @Test
    func `rotate recording file bails when engine is tearing down`() async throws {
      let engine = AIOEngine()
      await engine.debugBypassEngineTeardownForTesting()
      let outputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "AIOEngineIntegrationTests-\(UUID().uuidString)", isDirectory: true,
        )
      defer { try? FileManager.default.removeItem(at: outputDirectory) }
      let configuration = makeConfiguration(outputDestination: .directory(outputDirectory))

      let url = try await engine.startTestRecording(configuration: configuration)
      defer { try? FileManager.default.removeItem(at: url) }
      engine.injectTestAudio(channels: [ramp(count: 256)])

      // Simulate a teardown that has raised the sentinel (as gracefulStop does
      // before its drain, while `isRecording` is still true).
      await MainActor.run { engine.debugSetEngineTearingDownForTesting(true) }

      await #expect(throws: RecordingError.notRecording) {
        _ = try await engine.rotateRecordingFile()
      }

      // No swap happened: the recording URL is unchanged, and the discarded
      // rotation file was removed (only the original remains in the directory).
      #expect(await engine.debugCurrentRecordingURL() == url)
      let remaining = try FileManager.default.contentsOfDirectory(
        at: outputDirectory, includingPropertiesForKeys: nil,
      )
      #expect(remaining.map(\.lastPathComponent) == [url.lastPathComponent])

      await MainActor.run { engine.debugSetEngineTearingDownForTesting(false) }
      _ = try? await engine.stopRecording()
    }

    private func makeConfiguration(
      channels: ChannelCount = .mono,
      outputDestination: RecordingConfiguration.OutputDestination = .temporary,
    ) -> RecordingConfiguration {
      let input = InputConfiguration(
        sampleRate: .dvd,
        channels: channels,
      )
      let output = OutputConfiguration(
        fileFormat: .caf,
        bitDepth: .pcmFloat32,
        quality: .high,
      )
      return RecordingConfiguration(
        inputConfiguration: input,
        outputConfiguration: output,
        outputDestination: outputDestination,
      )
    }

    private func makeSessionSnapshot() -> AudioSessionSnapshot {
      AudioSessionSnapshot(
        category: AVAudioSession.Category.record.rawValue,
        mode: AVAudioSession.Mode.default.rawValue,
        options: [],
        sampleRate: 48_000,
        ioBufferDuration: 0.01,
        inputNumberOfChannels: 1,
        isInputAvailable: true,
      )
    }

    private func makeStereoConfiguration() -> RecordingConfiguration {
      let input = InputConfiguration(
        sampleRate: .dvd,
        channels: .stereo,
      )
      let output = OutputConfiguration(
        fileFormat: .caf,
        bitDepth: .pcmFloat32,
        quality: .high,
      )
      return RecordingConfiguration(
        inputConfiguration: input,
        outputConfiguration: output,
        outputDestination: .temporary,
      )
    }

    private func ramp(count: Int) -> [Float] {
      guard count > 0 else { return [] }
      return (0..<count).map { Float($0) / Float(count) }
    }

  }

  private func makeMockTapInstallResult(
    tapFormat: AVAudioFormat,
    processingFormat: AVAudioFormat,
  ) throws(RecordingError) -> TapInstallResult {
    guard let converter = AVAudioConverter(from: tapFormat, to: processingFormat) else {
      throw RecordingError.formatConversionFailed
    }
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: processingFormat,
        frameCapacity: 1024,
      )
    else {
      throw RecordingError.formatConversionFailed
    }
    let artifacts = TapConversionArtifacts(
      converter: converter,
      inputFormat: tapFormat,
      convertedBuffer: buffer,
    )
    let tapConfig = TapConfiguration(
      bus: 0,
      inputFormat: tapFormat,
      outputFormat: processingFormat,
      bufferSize: 1024,
    )
    return TapInstallResult(
      tapFormat: tapFormat,
      artifacts: artifacts,
      tapConfiguration: tapConfig,
    )
  }

  // SAFETY: All mutable state is protected by NSLock, only accessed under lock.
  private final class CapturingReceiver: BufferReceiver, @unchecked Sendable {
    typealias T = Float
    private let lock = NSLock()
    private let received = AsyncContinuation<Void>()
    private var storedValues: [Float] = []
    private var storedTiming: BufferTiming?

    func snapshot() -> (values: [Float], timing: BufferTiming?) {
      lock.lock()
      defer { lock.unlock() }
      return (storedValues, storedTiming)
    }

    func waitUntilReceived() async -> Bool {
      if !snapshot().values.isEmpty {
        return true
      }
      await received()
      return !snapshot().values.isEmpty
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>) {
      unsafe processBuffer(data, timing: BufferTiming(sampleTime: 0, sampleRate: 48000))
    }

    nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>, timing: BufferTiming) {
      lock.lock()
      storedValues = unsafe Array(data)
      storedTiming = timing
      lock.unlock()
      try? received.yield()
    }

    nonisolated func endBufferTask() {}
  }

  // SAFETY: All mutable state is protected by NSLock, only accessed under lock.
  private final class RouteFaultProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var interruptions: [AIOEngine.RecordingInterruption] = []
    private var failureCount: Int = 0

    func record(_ interruption: AIOEngine.RecordingInterruption) {
      lock.lock()
      interruptions.append(interruption)
      lock.unlock()
    }

    func recordFailure() {
      lock.lock()
      failureCount += 1
      lock.unlock()
    }

    func snapshot() -> (interruptions: [AIOEngine.RecordingInterruption], failureCount: Int) {
      lock.lock()
      defer { lock.unlock() }
      return (interruptions, failureCount)
    }

    /// Subscribes to `engine.events` before returning and owns the subscription
    /// behind the cancellable work handle.
    @MainActor
    func bridge(to engine: AIOEngine) -> RouteFaultBridge {
      let subscription = engine.events.subscribe()
      let probe = self
      let work = MainActorOwnedWork {
        for await event in subscription.events {
          switch event {
          case .recordingInterruption(let interruption):
            probe.record(interruption)
          case .recordingFailed:
            probe.recordFailure()
          default:
            break
          }
        }
      }
      return RouteFaultBridge(subscription: subscription, work: work)
    }
  }

  private struct RouteFaultBridge: Sendable {
    let subscription: AsyncBroadcaster<AudioIOEvent>.Subscription
    let work: MainActorOwnedWork

    func cancelNow() {
      subscription.cancel()
      work.cancelNow()
    }

    func cancel() async {
      subscription.cancel()
      await work.cancel()
    }
  }

  private func waitUntil(
    timeout: Duration,
    condition: @escaping @Sendable () async -> Bool,
  ) async -> Bool {
    let clock = ContinuousClock()
    let polling = PollingPolicy(interval: .milliseconds(10))
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await condition() { return true }
      try? await polling.waitForNextPoll()
    }
    return await condition()
  }

  // SAFETY: All mutable state is protected by NSLock, only accessed under lock.
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
