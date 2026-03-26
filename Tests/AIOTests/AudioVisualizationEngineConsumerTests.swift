// © GoodHatsLLC

#if canImport(AVFAudio)
  @testable import AIOAudioSession
  import AIOEngine
  import AudioSignals
  import Foundation
  import Testing

  struct AudioVisualizationEngineConsumerTests {
    @Test
    @MainActor
    func `eventMask none emits no callbacks`() async {
      let engine = AudioVisualizationEngine(
        configuration: .lowPower.withSampleRate(48000),
      )
      let recorder = EventCountRecorder()
      let request = VisualizationRequest(
        work: .none,
        eventMask: .none,
      )

      let subscription = engine.subscribe(request: request) { event in
        Task { await recorder.record(event) }
      }

      engine.startVisualization()
      sendBuffer(engine, sampleTime: 0)
      try? await Task.sleep(for: .milliseconds(80))

      let snapshot = await recorder.snapshot()
      #expect(snapshot.totalCount == 0)

      subscription.cancel()
      engine.stopVisualization()
    }

    @Test
    @MainActor
    func `eventMask filters each event kind`() async {
      let engine = AudioVisualizationEngine(
        configuration: .lowPower.withSampleRate(48000),
      )
      let timingRecorder = EventCountRecorder()
      let lodRecorder = EventCountRecorder()

      let timingSubscription = engine.subscribe(
        request: VisualizationRequest(
          work: .none,
          eventMask: [.latestBufferTiming],
        ),
      ) { event in
        Task { await timingRecorder.record(event) }
      }

      let lodSubscription = engine.subscribe(
        request: VisualizationRequest(
          work: VisualizationWork(
            lod: LODWork(
              configuration: MultiBandLODConfiguration(
                lodRatio: 8,
                snapshotSwapInterval: 1,
              ),
              publishRateHz: 120,
            ),
          ),
          eventMask: [.lodSnapshotBackground, .lodSnapshot],
        ),
      ) { event in
        Task { await lodRecorder.record(event) }
      }

      engine.startVisualization()
      for step in 0..<8 {
        sendBuffer(engine, sampleTime: Int64(step * 64))
        try? await Task.sleep(for: .milliseconds(8))
      }

      #expect(
        await waitUntilAsync {
          let timing = await timingRecorder.snapshot()
          let lod = await lodRecorder.snapshot()
          return timing.latestBufferTimingCount > 0 && lod.lodSnapshotCount > 0
        },
      )

      let timingSnapshot = await timingRecorder.snapshot()
      #expect(timingSnapshot.latestBufferTimingCount > 0)
      #expect(timingSnapshot.lodSnapshotCount == 0)
      #expect(timingSnapshot.lodSnapshotBackgroundCount == 0)
      #expect(timingSnapshot.timeDomainCount == 0)
      #expect(timingSnapshot.frequencyDomainCount == 0)
      #expect(timingSnapshot.beatCount == 0)

      let lodSnapshot = await lodRecorder.snapshot()
      #expect(lodSnapshot.latestBufferTimingCount == 0)
      #expect(lodSnapshot.lodSnapshotCount > 0 || lodSnapshot.lodSnapshotBackgroundCount > 0)

      timingSubscription.cancel()
      lodSubscription.cancel()
      engine.stopVisualization()
    }

    @Test
    @MainActor
    func `lod work is active even when eventMask is none`() async {
      let engine = AudioVisualizationEngine(
        configuration: .lowPower.withSampleRate(48000),
      )
      let request = VisualizationRequest(
        work: VisualizationWork(
          lod: LODWork(
            configuration: MultiBandLODConfiguration(
              lodRatio: 8,
              snapshotSwapInterval: 1,
            ),
            publishRateHz: 120,
          ),
        ),
        eventMask: .none,
      )

      let subscription = engine.subscribe(request: request) { _ in }

      engine.startVisualization()
      for step in 0..<8 {
        sendBuffer(engine, sampleTime: Int64(step * 64))
      }
      try? await Task.sleep(for: .milliseconds(50))

      let hasLodRef = engine.withCurrentLODSnapshotRef { _ in true } ?? false
      #expect(hasLodRef)

      subscription.cancel()
      engine.stopVisualization()
    }

    @Test
    @MainActor
    func `latestBufferTiming is not dispatched when not requested`() async {
      let engine = AudioVisualizationEngine(
        configuration: .lowPower.withSampleRate(48000),
      )
      let recorder = EventCountRecorder()
      let request = VisualizationRequest(
        work: .none,
        eventMask: [.lodSnapshotBackground],
      )

      let subscription = engine.subscribe(request: request) { event in
        Task { await recorder.record(event) }
      }

      engine.startVisualization()
      sendBuffer(engine, sampleTime: 0)
      try? await Task.sleep(for: .milliseconds(80))

      let snapshot = await recorder.snapshot()
      #expect(snapshot.latestBufferTimingCount == 0)

      subscription.cancel()
      engine.stopVisualization()
    }

    @Test
    @MainActor
    func `Subscriptions fan out latest buffer timing and support cancellation`() async {
      let engine = AudioVisualizationEngine(
        configuration: .lowPower.withSampleRate(48000),
      )
      let firstRecorder = VisualizationEventRecorder()
      let secondRecorder = VisualizationEventRecorder()
      let request = VisualizationRequest(work: .none)

      let first = engine.subscribe(request: request) { event in
        Task { await firstRecorder.record(event) }
      }
      let second = engine.subscribe(request: request) { event in
        Task { await secondRecorder.record(event) }
      }

      engine.startVisualization()
      sendBuffer(engine, sampleTime: 0)

      #expect(
        await waitUntilAsync {
          let firstSnapshot = await firstRecorder.snapshot()
          let secondSnapshot = await secondRecorder.snapshot()
          return firstSnapshot.sampleTimes == [0] && secondSnapshot.sampleTimes == [0]
        },
      )

      first.cancel()
      sendBuffer(engine, sampleTime: 64)

      #expect(
        await waitUntilAsync {
          let secondSnapshot = await secondRecorder.snapshot()
          return secondSnapshot.sampleTimes == [0, 64]
        },
      )

      let firstAfterCancel = await firstRecorder.snapshot()
      #expect(firstAfterCancel.sampleTimes == [0])

      second.cancel()
      sendBuffer(engine, sampleTime: 128)
      try? await Task.sleep(for: .milliseconds(80))

      let secondAfterCancel = await secondRecorder.snapshot()
      #expect(secondAfterCancel.sampleTimes == [0, 64])
      engine.stopVisualization()
    }

    @Test
    @MainActor
    func `Subscriptions fan out LOD background snapshots`() async {
      let engine = AudioVisualizationEngine(
        configuration: .lowPower.withSampleRate(48000),
      )
      let firstRecorder = VisualizationEventRecorder()
      let secondRecorder = VisualizationEventRecorder()

      let request = VisualizationRequest(
        work: VisualizationWork(
          lod: LODWork(
            configuration: MultiBandLODConfiguration(
              lodRatio: 8,
              snapshotSwapInterval: 1,
            ),
            publishRateHz: 120,
          ),
        ),
      )

      let first = engine.subscribe(request: request) { event in
        Task { await firstRecorder.record(event) }
      }
      let second = engine.subscribe(request: request) { event in
        Task { await secondRecorder.record(event) }
      }

      engine.startVisualization()
      for step in 0..<8 {
        sendBuffer(engine, sampleTime: Int64(step * 64))
        try? await Task.sleep(for: .milliseconds(8))
      }

      #expect(
        await waitUntilAsync {
          let firstSnapshot = await firstRecorder.snapshot()
          let secondSnapshot = await secondRecorder.snapshot()
          return firstSnapshot.lodBackgroundCount > 0 && secondSnapshot.lodBackgroundCount > 0
        },
      )

      first.cancel()
      second.cancel()
      engine.stopVisualization()
    }

    @Test
    @MainActor
    func `Subscriptions can join late and cancel independently`() async {
      let engine = AudioVisualizationEngine(
        configuration: .lowPower.withSampleRate(48000),
      )
      let firstRecorder = VisualizationEventRecorder()
      let secondRecorder = VisualizationEventRecorder()
      let request = VisualizationRequest(work: .none)

      let first = engine.subscribe(request: request) { event in
        Task { await firstRecorder.record(event) }
      }
      engine.startVisualization()

      sendBuffer(engine, sampleTime: 0)
      #expect(
        await waitUntilAsync {
          let firstSnapshot = await firstRecorder.snapshot()
          let secondSnapshot = await secondRecorder.snapshot()
          return firstSnapshot.sampleTimes == [0] && secondSnapshot.sampleTimes.isEmpty
        },
      )

      let second = engine.subscribe(request: request) { event in
        Task { await secondRecorder.record(event) }
      }
      sendBuffer(engine, sampleTime: 64)
      #expect(
        await waitUntilAsync {
          let firstSnapshot = await firstRecorder.snapshot()
          let secondSnapshot = await secondRecorder.snapshot()
          return firstSnapshot.sampleTimes == [0, 64] && secondSnapshot.sampleTimes == [64]
        },
      )

      first.cancel()
      sendBuffer(engine, sampleTime: 128)
      #expect(
        await waitUntilAsync {
          let firstSnapshot = await firstRecorder.snapshot()
          let secondSnapshot = await secondRecorder.snapshot()
          return firstSnapshot.sampleTimes == [0, 64] && secondSnapshot.sampleTimes == [64, 128]
        },
      )

      second.cancel()
      sendBuffer(engine, sampleTime: 192)
      try? await Task.sleep(for: .milliseconds(80))

      let firstAfterCancel = await firstRecorder.snapshot()
      let secondAfterCancel = await secondRecorder.snapshot()
      #expect(firstAfterCancel.sampleTimes == [0, 64])
      #expect(secondAfterCancel.sampleTimes == [64, 128])

      engine.stopVisualization()
    }

    @Test
    @MainActor
    func `Main and background events dispatch on expected threads`() async {
      let engine = AudioVisualizationEngine(
        configuration: .lowPower.withSampleRate(48000),
      )
      let backgroundCapture = BackgroundSinkCapture()
      let work = VisualizationWork(
        lod: LODWork(
          configuration: MultiBandLODConfiguration(
            lodRatio: 8,
            snapshotSwapInterval: 1,
          ),
          publishRateHz: 120,
        ),
      )
      var latestTimingThreadsAreMain: [Bool] = []
      var lodMainCallbackCount = 0
      var lodMainThreadsAreMain: [Bool] = []

      let subscription = engine.subscribe(
        request: VisualizationRequest(work: work),
        handler: { event in
          switch event {
          case .lodSnapshot:
            guard engine.withCurrentLODSnapshotRef({ _ in true }) == true else { return }
            Task { @MainActor in
              lodMainCallbackCount += 1
              lodMainThreadsAreMain.append(true)
            }
          case .lodSnapshotBackground:
            let isMainThread = Thread.isMainThread
            let hasSnapshot = engine.withCurrentLODSnapshotRef { _ in true } ?? false
            Task {
              await backgroundCapture.record(
                isMainThread: isMainThread,
                hasSnapshot: hasSnapshot,
              )
            }
          case .latestBufferTiming(let timing):
            guard timing != nil else { return }
            Task { @MainActor in
              latestTimingThreadsAreMain.append(true)
            }
          case .timeDomain, .frequencyDomain, .beat:
            break
          }
        },
      )
      engine.startVisualization()

      for step in 0..<6 {
        sendBuffer(engine, sampleTime: Int64(step * 64))
        try? await Task.sleep(for: .milliseconds(5))
      }

      #expect(await waitUntil { !latestTimingThreadsAreMain.isEmpty })
      #expect(await waitUntil { lodMainCallbackCount > 0 })
      #expect(await waitForBackgroundCallbacks(backgroundCapture))

      #expect(latestTimingThreadsAreMain.allSatisfy { $0 })
      #expect(lodMainThreadsAreMain.allSatisfy { $0 })

      let background = await backgroundCapture.snapshot()
      #expect(background.callbackCount > 0)
      #expect(background.sawNonMainThread)
      #expect(background.sawSnapshot)

      subscription.cancel()
      engine.stopVisualization()
    }

    @MainActor
    private func sendBuffer(
      _ engine: AudioVisualizationEngine,
      sampleTime: Int64,
      sampleRate: Double = 48000,
      count: Int = 64,
    ) {
      let samples = [Float](repeating: 0.25, count: count)
      unsafe samples.withUnsafeBufferPointer { buffer in
        unsafe engine.processBuffer(
          buffer,
          timing: BufferTiming(sampleTime: sampleTime, sampleRate: sampleRate),
        )
      }
    }

    @MainActor
    private func waitUntil(
      timeout: Duration = .seconds(1),
      condition: @MainActor () -> Bool,
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
    private func waitUntilAsync(
      timeout: Duration = .seconds(1),
      condition: @Sendable () async -> Bool,
    ) async -> Bool {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: timeout)
      while clock.now < deadline {
        if await condition() {
          return true
        }
        try? await Task.sleep(for: .milliseconds(10))
      }
      return await condition()
    }

    @MainActor
    private func waitForBackgroundCallbacks(
      _ capture: BackgroundSinkCapture,
      timeout: Duration = .seconds(2),
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
      return await (capture.snapshot()).callbackCount > 0
    }
  }

  private actor BackgroundSinkCapture {
    struct Snapshot {
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
        sawSnapshot: sawSnapshot,
      )
    }
  }

  private actor VisualizationEventRecorder {
    struct Snapshot {
      let sampleTimes: [Int64]
      let lodBackgroundCount: Int
    }

    private var sampleTimes: [Int64] = []
    private var lodBackgroundCount: Int = 0

    func record(_ event: VisualizationEvent) {
      switch event {
      case .latestBufferTiming(let timing):
        if let timing {
          sampleTimes.append(timing.sampleTime)
        }
      case .lodSnapshotBackground:
        lodBackgroundCount += 1
      default:
        break
      }
    }

    func snapshot() -> Snapshot {
      Snapshot(
        sampleTimes: sampleTimes,
        lodBackgroundCount: lodBackgroundCount,
      )
    }
  }

  private actor EventCountRecorder {
    struct Snapshot {
      let lodSnapshotCount: Int
      let lodSnapshotBackgroundCount: Int
      let timeDomainCount: Int
      let frequencyDomainCount: Int
      let beatCount: Int
      let latestBufferTimingCount: Int

      var totalCount: Int {
        lodSnapshotCount
          + lodSnapshotBackgroundCount
          + timeDomainCount
          + frequencyDomainCount
          + beatCount
          + latestBufferTimingCount
      }
    }

    private var lodSnapshotCount = 0
    private var lodSnapshotBackgroundCount = 0
    private var timeDomainCount = 0
    private var frequencyDomainCount = 0
    private var beatCount = 0
    private var latestBufferTimingCount = 0

    func record(_ event: VisualizationEvent) {
      switch event {
      case .lodSnapshot:
        lodSnapshotCount += 1
      case .lodSnapshotBackground:
        lodSnapshotBackgroundCount += 1
      case .timeDomain:
        timeDomainCount += 1
      case .frequencyDomain:
        frequencyDomainCount += 1
      case .beat:
        beatCount += 1
      case .latestBufferTiming:
        latestBufferTimingCount += 1
      }
    }

    func snapshot() -> Snapshot {
      Snapshot(
        lodSnapshotCount: lodSnapshotCount,
        lodSnapshotBackgroundCount: lodSnapshotBackgroundCount,
        timeDomainCount: timeDomainCount,
        frequencyDomainCount: frequencyDomainCount,
        beatCount: beatCount,
        latestBufferTimingCount: latestBufferTimingCount,
      )
    }
  }
#endif
