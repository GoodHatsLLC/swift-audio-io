#if canImport(AVFAudio)
  import Foundation
  import Testing

  import AIOEngine
  import AudioSignals

  @Suite("AudioVisualizationEngine Consumer API")
  struct AudioVisualizationEngineConsumerTests {
    @Test("Register/unregister uses active consumer semantics")
    @MainActor
    func registerAndUnregisterActiveConsumer() async {
      let engine = AudioVisualizationEngine(
        configuration: .lowPower.withSampleRate(48_000)
      )
      let first = TestVisualizationConsumer(work: .none, includeTiming: true)
      let second = TestVisualizationConsumer(work: .none, includeTiming: true)

      engine.register(consumer: first)
      engine.startVisualization()

      sendBuffer(engine, sampleTime: 0)
      #expect(await waitUntil { first.latestSampleTimes.count == 1 })
      #expect(first.latestSampleTimes == [0])
      #expect(second.latestSampleTimes.isEmpty)

      engine.register(consumer: second)
      sendBuffer(engine, sampleTime: 64)
      #expect(await waitUntil { second.latestSampleTimes.count == 1 })
      #expect(second.latestSampleTimes == [64])
      #expect(first.latestSampleTimes == [0])

      // Unregistering a non-active consumer should be a no-op.
      engine.unregister(consumer: first)
      sendBuffer(engine, sampleTime: 128)
      #expect(await waitUntil { second.latestSampleTimes.count == 2 })
      #expect(second.latestSampleTimes == [64, 128])
      #expect(first.latestSampleTimes == [0])

      // Unregistering the active consumer should stop sink delivery.
      engine.unregister(consumer: second)
      sendBuffer(engine, sampleTime: 192)
      try? await Task.sleep(for: .milliseconds(80))
      #expect(second.latestSampleTimes == [64, 128])

      engine.stopVisualization()
    }

    @Test("Main and background sinks dispatch on expected threads")
    @MainActor
    func sinkThreadDelivery() async {
      let engine = AudioVisualizationEngine(
        configuration: .lowPower.withSampleRate(48_000)
      )
      let backgroundCapture = BackgroundSinkCapture()
      let work = VisualizationWork(
        lod: LODWork(
          configuration: MultiBandLODConfiguration(
            lodRatio: 8,
            snapshotSwapInterval: 1
          ),
          publishRateHz: 120
        )
      )
      let consumer = TestVisualizationConsumer(
        work: work,
        includeTiming: true,
        includeLodMain: true,
        includeLodBackground: true,
        backgroundCapture: backgroundCapture
      )

      engine.register(consumer: consumer)
      engine.startVisualization()

      for step in 0..<6 {
        sendBuffer(engine, sampleTime: Int64(step * 64))
        try? await Task.sleep(for: .milliseconds(5))
      }

      #expect(await waitUntil { !consumer.latestTimingThreadsAreMain.isEmpty })
      #expect(await waitUntil { consumer.lodMainCallbackCount > 0 })
      #expect(await waitForBackgroundCallbacks(backgroundCapture))

      #expect(consumer.latestTimingThreadsAreMain.allSatisfy { $0 })
      #expect(consumer.lodMainThreadsAreMain.allSatisfy { $0 })

      let background = await backgroundCapture.snapshot()
      #expect(background.callbackCount > 0)
      #expect(background.sawNonMainThread)
      #expect(background.sawSnapshot)

      engine.stopVisualization()
    }

    @MainActor
    private func sendBuffer(
      _ engine: AudioVisualizationEngine,
      sampleTime: Int64,
      sampleRate: Double = 48_000,
      count: Int = 64
    ) {
      let samples = [Float](repeating: 0.25, count: count)
      unsafe samples.withUnsafeBufferPointer { buffer in
        unsafe engine.processBuffer(
          buffer,
          timing: BufferTiming(sampleTime: sampleTime, sampleRate: sampleRate)
        )
      }
    }

    @MainActor
    private func waitUntil(
      timeout: Duration = .seconds(1),
      condition: @MainActor () -> Bool
    ) async -> Bool {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: timeout)
      while clock.now < deadline {
        if condition() {
          return true
        }
        try? await Task.sleep(for: .milliseconds(10))
      }
      return condition()
    }

    @MainActor
    private func waitForBackgroundCallbacks(
      _ capture: BackgroundSinkCapture,
      timeout: Duration = .seconds(2)
    ) async -> Bool {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: timeout)
      while clock.now < deadline {
        let snapshot = await capture.snapshot()
        if snapshot.callbackCount > 0 {
          return true
        }
        try? await Task.sleep(for: .milliseconds(10))
      }
      return (await capture.snapshot()).callbackCount > 0
    }
  }

  @MainActor
  private final class TestVisualizationConsumer: VisualizationConsumer {
    var work: VisualizationWork
    private let includeTiming: Bool
    private let includeLodMain: Bool
    private let includeLodBackground: Bool
    private let backgroundCapture: BackgroundSinkCapture?

    var latestSampleTimes: [Int64] = []
    var latestTimingThreadsAreMain: [Bool] = []
    var lodMainCallbackCount: Int = 0
    var lodMainThreadsAreMain: [Bool] = []

    init(
      work: VisualizationWork,
      includeTiming: Bool,
      includeLodMain: Bool = false,
      includeLodBackground: Bool = false,
      backgroundCapture: BackgroundSinkCapture? = nil
    ) {
      self.work = work
      self.includeTiming = includeTiming
      self.includeLodMain = includeLodMain
      self.includeLodBackground = includeLodBackground
      self.backgroundCapture = backgroundCapture
    }

    var sinks: VisualizationSinks {
      var lodSnapshotHandler: (@MainActor (LODSnapshotRef?) -> Void)?
      if includeLodMain {
        lodSnapshotHandler = { [weak self] (_: LODSnapshotRef?) in
          guard let self else { return }
          self.lodMainCallbackCount += 1
          self.lodMainThreadsAreMain.append(Thread.isMainThread)
        }
      }

      var lodSnapshotBackgroundHandler: (@Sendable (LODSnapshotRef?) -> Void)?
      if includeLodBackground {
        lodSnapshotBackgroundHandler = { [backgroundCapture] snapshot in
          guard let backgroundCapture else { return }
          let isMainThread = Thread.isMainThread
          Task {
            await backgroundCapture.record(
              isMainThread: isMainThread,
              hasSnapshot: snapshot != nil
            )
          }
        }
      }

      var latestTimingHandler: (@MainActor (BufferTiming?) -> Void)?
      if includeTiming {
        latestTimingHandler = { [weak self] timing in
          guard let self, let timing else { return }
          self.latestSampleTimes.append(timing.sampleTime)
          self.latestTimingThreadsAreMain.append(Thread.isMainThread)
        }
      }

      return VisualizationSinks(
        lodSnapshot: lodSnapshotHandler,
        lodSnapshotBackground: lodSnapshotBackgroundHandler,
        latestBufferTiming: latestTimingHandler
      )
    }
  }

  private actor BackgroundSinkCapture {
    struct Snapshot: Sendable {
      let callbackCount: Int
      let sawNonMainThread: Bool
      let sawSnapshot: Bool
    }

    private var callbackCount = 0
    private var sawNonMainThread = false
    private var sawSnapshot = false

    func record(isMainThread: Bool, hasSnapshot: Bool) {
      callbackCount += 1
      sawNonMainThread = sawNonMainThread || !isMainThread
      sawSnapshot = sawSnapshot || hasSnapshot
    }

    func snapshot() -> Snapshot {
      Snapshot(
        callbackCount: callbackCount,
        sawNonMainThread: sawNonMainThread,
        sawSnapshot: sawSnapshot
      )
    }
  }
#endif
