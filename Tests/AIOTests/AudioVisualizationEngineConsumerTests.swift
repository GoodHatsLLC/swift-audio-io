// © GoodHatsLLC

#if canImport(AVFAudio)
  @testable import AIOAudioSession
  import AudioIO
  import AudioSignals
  import Foundation
  import Testing
  import Tools

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
        recorder.record(event)
      }

      engine.startVisualization()
      sendBuffer(engine, sampleTime: 0)
      await engine.debugDrainVisualizationDeliveryForTesting()

      let snapshot = recorder.snapshot()
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
        timingRecorder.record(event)
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
        lodRecorder.record(event)
      }

      engine.startVisualization()
      for step in 0..<8 {
        sendBuffer(engine, sampleTime: Int64(step * 64))
      }
      engine.debugPublishLODSnapshotForTesting()
      await engine.debugDrainVisualizationDeliveryForTesting()

      let timingSnapshot = timingRecorder.snapshot()
      #expect(timingSnapshot.latestBufferTimingCount > 0)
      #expect(timingSnapshot.lodSnapshotCount == 0)
      #expect(timingSnapshot.lodSnapshotBackgroundCount == 0)
      #expect(timingSnapshot.timeDomainCount == 0)
      #expect(timingSnapshot.frequencyDomainCount == 0)
      #expect(timingSnapshot.beatCount == 0)

      let lodSnapshot = lodRecorder.snapshot()
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
        recorder.record(event)
      }

      engine.startVisualization()
      sendBuffer(engine, sampleTime: 0)
      await engine.debugDrainVisualizationDeliveryForTesting()

      let snapshot = recorder.snapshot()
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
        firstRecorder.record(event)
      }
      let second = engine.subscribe(request: request) { event in
        secondRecorder.record(event)
      }

      engine.startVisualization()
      sendBuffer(engine, sampleTime: 0)

      #expect(
        await firstRecorder.waitUntil { firstSnapshot in
          firstSnapshot.sampleTimes == [0] && secondRecorder.snapshot().sampleTimes == [0]
        },
      )

      first.cancel()
      sendBuffer(engine, sampleTime: 64)

      #expect(
        await secondRecorder.waitUntil { secondSnapshot in
          secondSnapshot.sampleTimes == [0, 64]
        },
      )

      let firstAfterCancel = firstRecorder.snapshot()
      #expect(firstAfterCancel.sampleTimes == [0])

      second.cancel()
      sendBuffer(engine, sampleTime: 128)
      await engine.debugDrainVisualizationDeliveryForTesting()

      let secondAfterCancel = secondRecorder.snapshot()
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
        firstRecorder.record(event)
      }
      let second = engine.subscribe(request: request) { event in
        secondRecorder.record(event)
      }

      engine.startVisualization()
      for step in 0..<8 {
        sendBuffer(engine, sampleTime: Int64(step * 64))
      }
      engine.debugPublishLODSnapshotForTesting()
      await engine.debugDrainVisualizationDeliveryForTesting()

      #expect(firstRecorder.snapshot().lodBackgroundCount > 0)
      #expect(secondRecorder.snapshot().lodBackgroundCount > 0)

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
        firstRecorder.record(event)
      }
      engine.startVisualization()

      sendBuffer(engine, sampleTime: 0)
      #expect(
        await firstRecorder.waitUntil { firstSnapshot in
          firstSnapshot.sampleTimes == [0] && secondRecorder.snapshot().sampleTimes.isEmpty
        },
      )

      let second = engine.subscribe(request: request) { event in
        secondRecorder.record(event)
      }
      sendBuffer(engine, sampleTime: 64)
      #expect(
        await firstRecorder.waitUntil { firstSnapshot in
          firstSnapshot.sampleTimes == [0, 64] && secondRecorder.snapshot().sampleTimes == [64]
        },
      )

      first.cancel()
      sendBuffer(engine, sampleTime: 128)
      #expect(
        await secondRecorder.waitUntil { secondSnapshot in
          firstRecorder.snapshot().sampleTimes == [0, 64]
            && secondSnapshot.sampleTimes == [64, 128]
        },
      )

      second.cancel()
      sendBuffer(engine, sampleTime: 192)
      await engine.debugDrainVisualizationDeliveryForTesting()

      let firstAfterCancel = firstRecorder.snapshot()
      let secondAfterCancel = secondRecorder.snapshot()
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
      let mainCapture = MainThreadEventCapture()

      let subscription = engine.subscribe(
        request: VisualizationRequest(work: work),
        handler: { event in
          switch event {
          case .lodSnapshot:
            guard engine.withCurrentLODSnapshotRef({ _ in true }) == true else { return }
            mainCapture.recordLod(isMainThread: Thread.isMainThread)
          case .lodSnapshotBackground:
            let isMainThread = Thread.isMainThread
            let hasSnapshot = engine.withCurrentLODSnapshotRef { _ in true } ?? false
            backgroundCapture.record(
              isMainThread: isMainThread,
              hasSnapshot: hasSnapshot,
            )
          case .latestBufferTiming(let timing):
            guard timing != nil else { return }
            mainCapture.recordLatestTiming(isMainThread: Thread.isMainThread)
          case .timeDomain, .frequencyDomain, .beat:
            break
          }
        },
      )
      engine.startVisualization()

      for step in 0..<6 {
        sendBuffer(engine, sampleTime: Int64(step * 64))
      }

      await engine.debugDrainVisualizationDeliveryForTesting()
      #expect(await mainCapture.waitForLatestTimingAndLod())
      #expect(await backgroundCapture.waitForCallback())

      let mainSnapshot = mainCapture.snapshot()
      #expect(mainSnapshot.latestTimingThreadsAreMain)
      #expect(mainSnapshot.lodThreadsAreMain)

      let background = backgroundCapture.snapshot()
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

  }

  // SAFETY: Test capture guarded by `lock`; `signal` is Sendable.
  private final class BackgroundSinkCapture: @unchecked Sendable {
    struct Snapshot {
      let callbackCount: Int
      let sawNonMainThread: Bool
      let sawSnapshot: Bool
    }

    private let lock = NSLock()
    private let signal = AsyncSignal<Void>()
    private var callbackCount = 0
    private var sawNonMainThread = false
    private var sawSnapshot = false

    func record(isMainThread: Bool, hasSnapshot: Bool) {
      lock.lock()
      callbackCount += 1
      sawNonMainThread = sawNonMainThread || !isMainThread
      sawSnapshot = sawSnapshot || hasSnapshot
      lock.unlock()
      signal.signal()
    }

    func snapshot() -> Snapshot {
      lock.lock()
      defer { lock.unlock() }
      return Snapshot(
        callbackCount: callbackCount,
        sawNonMainThread: sawNonMainThread,
        sawSnapshot: sawSnapshot,
      )
    }

    func waitForCallback() async -> Bool {
      await waitForSignal(signal.events()) { [self] in
        snapshot().callbackCount > 0
      }
    }
  }

  // SAFETY: Test capture guarded by `lock`; `signal` is Sendable.
  private final class MainThreadEventCapture: @unchecked Sendable {
    struct Snapshot {
      let latestTimingCount: Int
      let lodCount: Int
      let latestTimingThreadsAreMain: Bool
      let lodThreadsAreMain: Bool
    }

    private let lock = NSLock()
    private let signal = AsyncSignal<Void>()
    private var latestTimingCount = 0
    private var lodCount = 0
    private var latestTimingThreadsAreMain = true
    private var lodThreadsAreMain = true

    func recordLatestTiming(isMainThread: Bool) {
      lock.lock()
      latestTimingCount += 1
      latestTimingThreadsAreMain = latestTimingThreadsAreMain && isMainThread
      lock.unlock()
      signal.signal()
    }

    func recordLod(isMainThread: Bool) {
      lock.lock()
      lodCount += 1
      lodThreadsAreMain = lodThreadsAreMain && isMainThread
      lock.unlock()
      signal.signal()
    }

    func snapshot() -> Snapshot {
      lock.lock()
      defer { lock.unlock() }
      return Snapshot(
        latestTimingCount: latestTimingCount,
        lodCount: lodCount,
        latestTimingThreadsAreMain: latestTimingThreadsAreMain,
        lodThreadsAreMain: lodThreadsAreMain,
      )
    }

    func waitForLatestTimingAndLod() async -> Bool {
      await waitForSignal(signal.events(), timeout: .seconds(2)) { [self] in
        let snapshot = snapshot()
        return snapshot.latestTimingCount > 0 && snapshot.lodCount > 0
      }
    }
  }

  // SAFETY: Test recorder guarded by `lock`; `signal` is Sendable.
  private final class VisualizationEventRecorder: @unchecked Sendable {
    struct Snapshot {
      let sampleTimes: [Int64]
      let lodBackgroundCount: Int
    }

    private let lock = NSLock()
    private let signal = AsyncSignal<Void>()
    private var sampleTimes: [Int64] = []
    private var lodBackgroundCount: Int = 0

    func record(_ event: VisualizationEvent) {
      lock.lock()
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
      lock.unlock()
      signal.signal()
    }

    func snapshot() -> Snapshot {
      lock.lock()
      defer { lock.unlock() }
      return Snapshot(
        sampleTimes: sampleTimes,
        lodBackgroundCount: lodBackgroundCount,
      )
    }

    func waitUntil(_ condition: @escaping @Sendable (Snapshot) -> Bool) async -> Bool {
      await waitForSignal(signal.events()) { [self] in
        condition(snapshot())
      }
    }
  }

  // SAFETY: Test recorder guarded by `lock`.
  private final class EventCountRecorder: @unchecked Sendable {
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

    private let lock = NSLock()
    private var lodSnapshotCount = 0
    private var lodSnapshotBackgroundCount = 0
    private var timeDomainCount = 0
    private var frequencyDomainCount = 0
    private var beatCount = 0
    private var latestBufferTimingCount = 0

    func record(_ event: VisualizationEvent) {
      lock.lock()
      defer { lock.unlock() }
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
      lock.lock()
      defer { lock.unlock() }
      return Snapshot(
        lodSnapshotCount: lodSnapshotCount,
        lodSnapshotBackgroundCount: lodSnapshotBackgroundCount,
        timeDomainCount: timeDomainCount,
        frequencyDomainCount: frequencyDomainCount,
        beatCount: beatCount,
        latestBufferTimingCount: latestBufferTimingCount,
      )
    }
  }

  private func waitForSignal(
    _ events: AsyncSignalStream<Void>,
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () -> Bool,
  ) async -> Bool {
    if condition() {
      return true
    }

    return await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await _ in events {
          if condition() { return true }
        }
        return false
      }
      group.addTask {
        try? await TimeoutPolicy(timeout).waitForTimeout()
        return false
      }

      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }
  }
#endif
