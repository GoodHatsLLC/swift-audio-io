#if canImport(AVFAudio)
  import Atomics
  public import AudioSignals
  public import AVFAudio
  import Foundation
  public import Observation
  import os
  import Tools
  import QuartzCore

  private let log = SystemLog.make()

  /// A high-performance audio visualization engine that processes audio data for real-time display.
  ///
  /// This class provides time-domain (amplitude/waveform), frequency-domain (spectrum), and beat
  /// detection analysis with minimal CPU overhead. It can be used to create visualizations for
  /// live audio streams or pre-recorded audio files.
  ///
  /// ## New API
  ///
  /// The visualization engine now provides structured data through three main properties:
  /// - ``timeDomain``: Time-domain data including amplitude samples, peaks, and RMS level.
  /// - ``frequencyDomain``: Frequency-domain data with configurable bucketing and spectrum analysis.
  /// - ``beat``: Beat detection information with configurable sensitivity.
  ///
  /// ## Topics
  ///
  /// ### Creating a Visualization Engine
  ///
  /// - ``init(configuration:)``
  /// - ``Configuration``
  ///
  /// ### Controlling Visualization
  ///
  /// - ``startVisualization()``
  /// - ``subscribe(request:handler:)``
  /// - ``subscribe(request:sink:)``
  /// - ``stopVisualization()``
  /// - ``isActive``
  ///
  /// ### Receiving Audio Data
  ///
  /// - ``processAudioBuffer(_:)``
  /// - ``BufferReceiver``
  ///
  /// ### Accessing Visualization Data (New API)
  ///
  /// - ``timeDomain``
  /// - ``frequencyDomain``
  /// - ``beat``
  ///
  /// ### Configuring Visualization
  ///
  /// - ``VisualizationRequest``
  /// - ``VisualizationWork``
  /// - ``subscribe(request:handler:)``
  ///
  /// This type is `@unchecked Sendable` because it is used as a real-time audio callback
  /// target (via `BufferReceiver`) and is passed across concurrency boundaries.
  ///
  /// ## Safety
  /// - The audio thread only calls `processBuffer(_:)` (which uses atomics and does not
  ///   touch `@Observable` state directly).
  /// - Observable state (`timeDomain` / `frequencyDomain` / `beat`) is published from the
  ///   main queue.
  /// - LOD and analysis processing are configured from active subscriber requests.
  @safe @Observable
  // SAFETY: Cross-thread access is atomics/callback-boundary only; UI state is main-queue published.
  public final class AudioVisualizationEngine: @unchecked Sendable, Identifiable {
    // MARK: - Public Properties

    public let id: UUID = .init()

    // MARK: New Structured API

    /// Time-domain visualization data including amplitude samples, peaks, and levels.
    public var timeDomain: TimeDomainData = .empty

    /// Frequency-domain visualization data with configurable buckets.
    public var frequencyDomain: FrequencyDomainData = .empty

    /// Beat detection information.
    public var beat: BeatInfo = .empty

    /// Peak-hold values for the spectrum with decay applied.
    public var spectrumPeakHold: [Float] = []

    /// Cached frequency labels for UI overlays.
    public var frequencyLabels: [(frequency: Float, label: String)] = []

    /// A Boolean value that indicates whether the visualization engine is currently active.
    public var isActive = false
    private let isActiveAtomic = ManagedAtomic<Bool>(false)
    private let wantsActiveAtomic = ManagedAtomic<Bool>(false)
    private let isForegroundAtomic = ManagedAtomic<Bool>(true)
    private let hasSubscriberAtomic = ManagedAtomic<Bool>(false)
    private let analysisEnabledAtomic = ManagedAtomic<Bool>(false)
    private let lodEnabledAtomic = ManagedAtomic<Bool>(false)

    /// Most recently received buffer timing (published from the main queue).
    public var latestBufferTiming: BufferTiming?

    /// A monotonically-increasing audio clock derived from `BufferTiming.sampleTime`.
    ///
    /// This clock advances even when visualization processing is gated off by consumer visibility,
    /// so the app can rely on sample-accurate time while recording continues in the background.
    public nonisolated var currentTimeSeconds: TimeInterval {
      let endSampleTime = latestEndSampleTimeAtomic.load(ordering: .relaxed)
      let sampleRate = currentSampleRate
      return Double(endSampleTime) / max(sampleRate, 1)
    }

    /// Current sample rate derived from the latest `BufferTiming` seen by this engine.
    ///
    /// Falls back to the configured sample rate if no timing has been received yet.
    public nonisolated var currentSampleRate: Double {
      let bits = latestSampleRateBitsAtomic.load(ordering: .relaxed)
      let value = Double(bitPattern: bits)
      return value > 0 ? value : configuration.sampleRate
    }

    private let fallbackSampleTimeAtomic = ManagedAtomic<Int64>(0)
    private let latestEndSampleTimeAtomic = ManagedAtomic<Int64>(0)
    private let latestSampleRateBitsAtomic: ManagedAtomic<UInt64>
    private let lastBeatUpdateEndSampleTimeAtomic = ManagedAtomic<Int64>(0)

    // MARK: - Configuration

    /// A struct that defines the configuration for the audio visualization engine.
    public struct Configuration: Sendable {
      /// The number of samples to use for the amplitude waveform.
      public let amplitudeWindowSize: Int
      /// The number of bins to use for the spectrum analysis.
      public let spectrumSize: Int
      /// Fallback analysis update rate when a request does not specify one.
      public let analysisUpdateRateHz: Double
      /// A factor that controls the amount of smoothing applied to the visualization data.
      public let smoothingFactor: Float
      /// The nominal sample rate of the source audio.
      public let sampleRate: Double
      /// Configuration for the amplitude analyzer helper.
      public let amplitudeAnalyzerConfiguration: AmplitudeAnalyzer.Configuration
      /// Optional configuration for the frequency analyzer helper.
      public let frequencyAnalyzerConfiguration: FrequencyAnalyzer.Configuration?
      /// Configuration for frequency bucketing.
      public let bucketMode: FrequencyBucketMode
      /// Configuration for perceptual frequency weighting.
      public let frequencyWeighting: FrequencyWeighting
      /// Configuration for beat detection.
      public let beatDetectionConfiguration: BeatDetectionConfiguration

      /// Creates a new configuration for the audio visualization engine.
      ///
      /// - Parameters:
      ///   - amplitudeWindowSize: The number of samples to use for the amplitude waveform. Defaults to 512.
      ///   - spectrumSize: The number of bins to use for the spectrum analysis. Defaults to 256.
      ///   - analysisUpdateRateHz: Fallback analysis update rate in Hertz. Defaults to 30.0.
      ///   - smoothingFactor: A factor that controls the amount of smoothing applied. Defaults to 0.3.
      ///   - sampleRate: The nominal sample rate of the source audio. Defaults to 44100.0.
      ///   - bucketMode: The frequency bucketing mode. Defaults to MEL scale with 24 buckets.
      ///   - frequencyWeighting: Perceptual weighting applied to frequency buckets. Defaults to none.
      ///   - beatDetectionConfiguration: Beat detection configuration. Defaults to standard settings.
      public init(
        amplitudeWindowSize: Int = 512,
        spectrumSize: Int = 256,
        analysisUpdateRateHz: Double = VisualizationRateDefaults.analysisUpdateRateHz,
        smoothingFactor: Float = 0.3,
        sampleRate: Double = 44_100.0,
        amplitudeAnalyzerConfiguration: AmplitudeAnalyzer.Configuration? = nil,
        frequencyAnalyzerConfiguration: FrequencyAnalyzer.Configuration? = nil,
        bucketMode: FrequencyBucketMode = .default,
        frequencyWeighting: FrequencyWeighting = .none,
        beatDetectionConfiguration: BeatDetectionConfiguration = .default
      ) {
        self.amplitudeWindowSize = amplitudeWindowSize
        self.spectrumSize = spectrumSize
        self.analysisUpdateRateHz = analysisUpdateRateHz
        self.smoothingFactor = smoothingFactor
        self.sampleRate = sampleRate
        self.bucketMode = bucketMode
        self.frequencyWeighting = frequencyWeighting
        self.beatDetectionConfiguration = beatDetectionConfiguration

        if let amplitudeAnalyzerConfiguration {
          self.amplitudeAnalyzerConfiguration = amplitudeAnalyzerConfiguration
        } else {
          self.amplitudeAnalyzerConfiguration = AmplitudeAnalyzer.Configuration(
            windowSize: amplitudeWindowSize,
            smoothingFactor: smoothingFactor,
            peakDecayRate: 0.92,
            noiseFloor: 0.001
          )
        }

        if let frequencyAnalyzerConfiguration {
          self.frequencyAnalyzerConfiguration = frequencyAnalyzerConfiguration
        } else if spectrumSize > 0 {
          self.frequencyAnalyzerConfiguration = FrequencyAnalyzer.Configuration(
            fftSize: max(256, spectrumSize * 2),
            spectrumSize: spectrumSize,
            sampleRate: sampleRate,
            smoothingFactor: smoothingFactor,
            noiseFloor: -60.0,
            windowType: .hann
          )
        } else {
          self.frequencyAnalyzerConfiguration = nil
        }
      }
    }

    // MARK: - Multi-Band LOD (Optional)

    /// Multi-band Level-of-Detail processor for Metal visualization.
    /// Configured through `VisualizationWork.lod` from active subscribers.

    @ObservationIgnored
    private var lodProcessor: MultiBandLODProcessor?
    private var lodConfig: MultiBandLODConfiguration?

    /// Current multi-band LOD snapshot for GPU rendering (creates a copy).
    /// Returns nil if multi-band LOD is not enabled.
    /// For frame-scoped zero-copy access, use `withCurrentLODSnapshotRef(_:)`.
    public var multiBandLOD: MultiBandLODSnapshot? {
      unsafe lodProcessor?.snapshot()
    }

    /// Provides frame-scoped zero-copy access to current LOD data.
    ///
    /// Returns `nil` when multi-band LOD is not enabled.
    public func withCurrentLODSnapshotRef<R>(_ body: (LODSnapshotRef) -> R) -> R? {
      guard let processor = unsafe lodProcessor else { return nil }
      return unsafe processor.withCurrentLODSnapshotRef(body)
    }

    /// Whether multi-band LOD processing is enabled.
    public var isMultiBandLODEnabled: Bool {
      unsafe lodProcessor != nil
    }

    // MARK: - Private Properties

    private let configuration: Configuration

    private let processingQueue = DispatchQueue(
      label: "audio-visualization",
      qos: .userInteractive
    )
    private let lodPublishQueue = DispatchQueue(
      label: "audio-visualization.lod-publish",
      qos: .userInteractive
    )

    private typealias SubscriberEventHandler = @Sendable (VisualizationEvent) -> Void

    private struct SubscriberState: Sendable {
      let id: UUID
      var request: VisualizationRequest
      var eventHandler: SubscriberEventHandler
    }

    private func accepts(
      _ event: VisualizationEvent,
      mask: VisualizationEventMask
    ) -> Bool {
      switch event {
      case .lodSnapshot:
        mask.contains(.lodSnapshot)
      case .lodSnapshotBackground:
        mask.contains(.lodSnapshotBackground)
      case .timeDomain:
        mask.contains(.timeDomain)
      case .frequencyDomain:
        mask.contains(.frequencyDomain)
      case .beat:
        mask.contains(.beat)
      case .latestBufferTiming:
        mask.contains(.latestBufferTiming)
      }
    }

    private func deliver(
      _ event: VisualizationEvent,
      to subscribers: [SubscriberState]
    ) {
      for subscriber in subscribers where accepts(event, mask: subscriber.request.eventMask) {
        subscriber.eventHandler(event)
      }
    }

    private struct AnalysisFlags: OptionSet {
      let rawValue: Int
      static let timeDomain = AnalysisFlags(rawValue: 1 << 0)
      static let frequencyDomain = AnalysisFlags(rawValue: 1 << 1)
      static let beat = AnalysisFlags(rawValue: 1 << 2)
    }

    private struct AnalysisConfig: Equatable {
      var timeDomain: AmplitudeAnalyzer.Configuration?
      var frequencyDomain: FrequencyDomainWork?
      var beatDetection: BeatDetectionConfiguration?
    }

    @safe private final class AnalysisPipeline {
      let amplitudeAnalyzer: AmplitudeAnalyzer?
      let frequencyAnalyzer: FrequencyAnalyzer?
      let frequencyBucketer: FrequencyBucketer?
      let beatDetector: BeatDetector?
      let frequencySampleCount: Int
      let peakHoldDecayRate: Float
      let ringBuffer: SPSCRingBuffer<Float>
      let maxVisualizationSamples: Int
      var readScratchBuffer: [Float]

      init(config: AnalysisConfig, sampleRate: Double) {
        if let amplitudeConfig = config.timeDomain {
          self.amplitudeAnalyzer = AmplitudeAnalyzer(configuration: amplitudeConfig)
        } else {
          self.amplitudeAnalyzer = nil
        }

        var builtFrequencyAnalyzer: FrequencyAnalyzer?
        var frequencySampleCount = 0
        var frequencyBucketer: FrequencyBucketer?
        var peakHoldDecayRate: Float = 0.015

        if let frequencyWork = config.frequencyDomain {
          let frequencyConfig = frequencyWork.configuration
          frequencySampleCount = frequencyConfig.fftSize
          do {
            builtFrequencyAnalyzer = try FrequencyAnalyzer(configuration: frequencyConfig)
          } catch {
            log.error(
              "Failed to create FrequencyAnalyzer: \(error.localizedDescription, privacy: .public)"
            )
            frequencySampleCount = 0
          }
          frequencyBucketer = FrequencyBucketer(
            mode: frequencyWork.bucketMode,
            sampleRate: Float(sampleRate),
            peakHoldDecayRate: frequencyWork.peakHoldDecayRate,
            weighting: frequencyWork.weighting
          )
          peakHoldDecayRate = frequencyWork.peakHoldDecayRate
        }

        self.frequencyAnalyzer = builtFrequencyAnalyzer
        self.frequencySampleCount = frequencySampleCount
        self.frequencyBucketer = frequencyBucketer
        self.peakHoldDecayRate = peakHoldDecayRate

        if let beatConfig = config.beatDetection {
          self.beatDetector = BeatDetector(configuration: beatConfig)
        } else {
          self.beatDetector = nil
        }

        let maxSamples = max(config.timeDomain?.windowSize ?? 0, frequencySampleCount)
        let resolvedMaxSamples = max(maxSamples, 1)
        let ringCapacity = max(resolvedMaxSamples * 4, 1024)
        self.maxVisualizationSamples = resolvedMaxSamples
        self.ringBuffer = SPSCRingBuffer<Float>(capacity: ringCapacity)
        self.readScratchBuffer = Array(repeating: 0.0, count: resolvedMaxSamples)
      }
    }

    private let subscriberLock = NSLock()
    private var subscribersById: [UUID: SubscriberState] = [:]
    private var subscriberOrder: [UUID] = []
    private let analysisFlagsAtomic = ManagedAtomic<Int>(0)

    private var analysisConfig: AnalysisConfig?
    private var analysisPipeline: AnalysisPipeline?
    private var analysisUpdateRateHz: Double?
    private var lodPublishRateHz: Double?
    private var lodPublishIntervals: [Double] = []

    private var analysisTimer: (any DispatchSourceTimer)?
    private var lodPublishTimer: (any DispatchSourceTimer)?

    // MARK: - Initialization

    /// Creates a new audio visualization engine with the specified configuration.
    ///
    /// - Parameter configuration: The configuration to use for the visualization engine.
    public init(configuration: Configuration = Configuration()) {
      self.configuration = configuration
      self.latestSampleRateBitsAtomic = ManagedAtomic(configuration.sampleRate.bitPattern)
    }

    deinit {
      stopVisualization()
    }

    // MARK: - Public Interface

    /// Starts the visualization processing.
    public func startVisualization() {
      wantsActiveAtomic.store(true, ordering: .relaxed)
      updateProcessingState()
    }

    /// Subscribes to visualization events using an event handler closure.
    ///
    /// Multiple subscriptions can be active at once. Work demand is resolved as the
    /// union of all active requests.
    @MainActor
    public func subscribe(
      request: VisualizationRequest,
      handler: @escaping @Sendable (VisualizationEvent) -> Void
    ) -> VisualizationSubscription {
      let id = UUID()
      addSubscriber(
        id: id,
        request: request,
        eventHandler: handler
      )
      recalculateDemandAndApply()
      updateProcessingState()

      return VisualizationSubscription { [weak self] in
        self?.removeSubscription(id: id)
      }
    }

    /// Subscribes to visualization events via a sink object.
    @MainActor
    public func subscribe(
      request: VisualizationRequest,
      sink: any VisualizationSink
    ) -> VisualizationSubscription {
      subscribe(request: request) { [weak sink] event in
        guard let sink else { return }
        Task { @MainActor in
          sink.receive(event)
        }
      }
    }

    /// Pauses visualization processing without clearing buffers or resetting history.
    ///
    /// This is intended for app lifecycle transitions (e.g. backgrounding) where we
    /// want to stop doing work on the audio thread without losing LOD history.
    public func pauseVisualization() {
      isForegroundAtomic.store(false, ordering: .relaxed)
      updateProcessingState()
    }

    /// Resumes visualization processing after a pause.
    public func resumeVisualization() {
      isForegroundAtomic.store(true, ordering: .relaxed)
      updateProcessingState()
    }

    /// Stops the visualization processing.
    public func stopVisualization() {
      wantsActiveAtomic.store(false, ordering: .relaxed)
      updateProcessingState()

      // Clear data
      timeDomain = .empty
      frequencyDomain = .empty
      beat = .empty
      spectrumPeakHold.removeAll()
      latestBufferTiming = nil
      lastBeatUpdateEndSampleTimeAtomic.store(0, ordering: .relaxed)
      analysisPipeline?.frequencyBucketer?.resetPeakHold()
      analysisPipeline?.beatDetector?.reset()
      analysisPipeline?.ringBuffer.clear()
      fallbackSampleTimeAtomic.store(0, ordering: .relaxed)
      latestEndSampleTimeAtomic.store(0, ordering: .relaxed)
      latestSampleRateBitsAtomic.store(configuration.sampleRate.bitPattern, ordering: .relaxed)
      unsafe lodProcessor?.reset()

      log.info("Audio visualization stopped")
    }

    private func updateProcessingState() {
      let wantsActive = wantsActiveAtomic.load(ordering: .relaxed)
      let isForeground = isForegroundAtomic.load(ordering: .relaxed)
      let hasSubscriber = hasSubscriberAtomic.load(ordering: .relaxed)

      let shouldBeActive = wantsActive && isForeground && hasSubscriber
      let wasActive = isActiveAtomic.exchange(shouldBeActive, ordering: .relaxed)
      guard wasActive != shouldBeActive else { return }

      if shouldBeActive {
        updateAnalysisTimerIfNeeded()
        updateLodPublishTimerIfNeeded()
      } else {
        analysisTimer?.cancel()
        analysisTimer = nil
        lodPublishTimer?.cancel()
        lodPublishTimer = nil
      }

      isActive = shouldBeActive
    }

    /// Processes an `AVAudioPCMBuffer` for visualization.
    ///
    /// - Parameter buffer: The audio buffer to process.
    public func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
      guard isActiveAtomic.load(ordering: .relaxed),
        let floatData = unsafe buffer.floatChannelData?[0]
      else { return }

      let bufferPointer = unsafe UnsafeBufferPointer(
        start: floatData,
        count: Int(buffer.frameLength)
      )
      unsafe processBuffer(bufferPointer)
    }

    // MARK: - Private Methods
    private func addSubscriber(
      id: UUID,
      request: VisualizationRequest,
      eventHandler: @escaping SubscriberEventHandler
    ) {
      subscriberLock.lock()
      defer { subscriberLock.unlock() }
      let state = SubscriberState(
        id: id,
        request: request,
        eventHandler: eventHandler
      )
      subscribersById[id] = state
      subscriberOrder.append(id)
    }

    private func removeSubscriber(id: UUID) -> Bool {
      subscriberLock.lock()
      defer { subscriberLock.unlock() }
      guard subscribersById.removeValue(forKey: id) != nil else { return false }
      subscriberOrder.removeAll { $0 == id }
      return true
    }

    private func removeSubscription(id: UUID) {
      let removed = removeSubscriber(id: id)
      guard removed else { return }
      recalculateDemandAndApply()
      updateProcessingState()
    }

    private func subscriberSnapshots() -> [SubscriberState] {
      subscriberLock.lock()
      let snapshots = subscriberOrder.compactMap { subscribersById[$0] }
      subscriberLock.unlock()
      return snapshots
    }

    private func recalculateDemandAndApply() {
      let subscribers = subscriberSnapshots()
      hasSubscriberAtomic.store(!subscribers.isEmpty, ordering: .relaxed)
      let aggregatedWork = aggregatedWork(from: subscribers)
      applyWork(aggregatedWork)
    }

    private func aggregatedWork(from subscribers: [SubscriberState]) -> VisualizationWork {
      guard !subscribers.isEmpty else { return .none }

      var selectedLodConfig: MultiBandLODConfiguration?
      var maxLodPublishRate: Double?

      var analysisRequested = false
      var selectedAnalysisUpdateRate: Double?
      var selectedTimeDomain: AmplitudeAnalyzer.Configuration?
      var selectedFrequencyDomain: FrequencyDomainWork?
      var selectedBeatDetection: BeatDetectionConfiguration?

      for subscriber in subscribers {
        let work = subscriber.request.work

        if let lodWork = work.lod {
          let normalizedConfig = normalizedLODConfig(lodWork.configuration)
          if let selectedLodConfig, selectedLodConfig != normalizedConfig {
            log.warning(
              "Conflicting LOD configurations across subscribers. Using the first requested configuration."
            )
          } else {
            selectedLodConfig = normalizedConfig
          }
          maxLodPublishRate = max(maxLodPublishRate ?? 0, lodWork.publishRateHz)
        }

        guard let analysisWork = work.analysis else { continue }
        analysisRequested = true
        selectedAnalysisUpdateRate = max(
          selectedAnalysisUpdateRate ?? 0,
          analysisWork.updateRateHz
        )

        if selectedTimeDomain == nil {
          selectedTimeDomain = analysisWork.timeDomain
        } else if let requested = analysisWork.timeDomain, selectedTimeDomain != requested {
          log.warning(
            "Conflicting time-domain configurations across subscribers. Using the first requested configuration."
          )
        }

        if let frequencyDomainWork = analysisWork.frequencyDomain {
          let normalizedFrequency = normalizedFrequencyWork(frequencyDomainWork)
          if let selectedFrequencyDomain, selectedFrequencyDomain != normalizedFrequency {
            log.warning(
              "Conflicting frequency-domain configurations across subscribers. Using the first requested configuration."
            )
          } else {
            selectedFrequencyDomain = normalizedFrequency
          }
        }

        if let beatDetection = analysisWork.beatDetection {
          if let selectedBeatDetection, selectedBeatDetection != beatDetection {
            log.warning(
              "Conflicting beat-detection configurations across subscribers. Using the first requested configuration."
            )
          } else {
            selectedBeatDetection = beatDetection
          }
        }
      }

      var resolvedLodWork: LODWork?
      if let selectedLodConfig {
        resolvedLodWork = LODWork(
          configuration: selectedLodConfig,
          publishRateHz: maxLodPublishRate ?? VisualizationRateDefaults.lodPublishRateHz
        )
      }

      var resolvedAnalysisWork: AnalysisWork?
      let hasAnyAnalysisDemand =
        selectedTimeDomain != nil
        || selectedFrequencyDomain != nil
        || selectedBeatDetection != nil
      if analysisRequested && hasAnyAnalysisDemand {
        resolvedAnalysisWork = AnalysisWork(
          updateRateHz: selectedAnalysisUpdateRate ?? configuration.analysisUpdateRateHz,
          timeDomain: selectedTimeDomain,
          frequencyDomain: selectedFrequencyDomain,
          beatDetection: selectedBeatDetection
        )
      }

      return VisualizationWork(
        lod: resolvedLodWork,
        analysis: resolvedAnalysisWork
      )
    }

    private func applyWork(_ work: VisualizationWork) {
      let resolvedLodWork = work.lod
      let wantsLod = resolvedLodWork != nil
      lodPublishRateHz = resolvedLodWork?.publishRateHz

      if let lodWork = resolvedLodWork, wantsLod {
        let resolvedConfig = normalizedLODConfig(lodWork.configuration)
        if lodConfig != resolvedConfig {
          lodEnabledAtomic.store(false, ordering: .relaxed)
          unsafe lodProcessor = unsafe MultiBandLODProcessor(configuration: resolvedConfig)
          lodConfig = resolvedConfig
        }
        lodEnabledAtomic.store(true, ordering: .relaxed)
        log.info(
          "Visualization LOD: publishRate=\(lodWork.publishRateHz, privacy: .public)Hz snapshotSwapInterval=\(resolvedConfig.snapshotSwapInterval, privacy: .public) lodRatio=\(resolvedConfig.lodRatio, privacy: .public)"
        )
      } else {
        lodEnabledAtomic.store(false, ordering: .relaxed)
        unsafe lodProcessor = nil
        lodConfig = nil
      }

      var flags: AnalysisFlags = []
      if let analysisWork = work.analysis {
        if analysisWork.timeDomain != nil || analysisWork.beatDetection != nil {
          flags.insert(.timeDomain)
        }
        if analysisWork.frequencyDomain != nil {
          flags.insert(.frequencyDomain)
        }
        if analysisWork.beatDetection != nil {
          flags.insert(.beat)
        }
      }

      analysisFlagsAtomic.store(flags.rawValue, ordering: .relaxed)
      analysisEnabledAtomic.store(!flags.isEmpty, ordering: .relaxed)
      analysisUpdateRateHz =
        flags.isEmpty
        ? nil
        : (work.analysis?.updateRateHz ?? configuration.analysisUpdateRateHz)

      configureAnalysisPipelineIfNeeded(analysisWork: work.analysis, flags: flags)
      updateAnalysisTimerIfNeeded()
      updateLodPublishTimerIfNeeded()
    }

    private func normalizedLODConfig(_ config: MultiBandLODConfiguration)
      -> MultiBandLODConfiguration
    {
      let sampleRate = max(Int(configuration.sampleRate.rounded()), 1)
      return MultiBandLODConfiguration(
        bandCount: config.bandCount,
        lodRatio: config.lodRatio,
        bufferSeconds: config.bufferSeconds,
        sampleRate: sampleRate,
        crossoverMode: config.crossoverMode,
        snapshotSwapInterval: config.snapshotSwapInterval,
        rawBufferLengthOverride: config.rawBufferLengthOverride
      )
    }

    private func normalizedFrequencyWork(_ work: FrequencyDomainWork) -> FrequencyDomainWork {
      let config = work.configuration
      let sampleRate = configuration.sampleRate
      guard config.sampleRate != sampleRate else { return work }
      let adjusted = FrequencyAnalyzer.Configuration(
        fftSize: config.fftSize,
        spectrumSize: config.spectrumSize,
        sampleRate: sampleRate,
        smoothingFactor: config.smoothingFactor,
        noiseFloor: config.noiseFloor,
        windowType: config.windowType
      )
      return FrequencyDomainWork(
        configuration: adjusted,
        bucketMode: work.bucketMode,
        peakHoldDecayRate: work.peakHoldDecayRate,
        weighting: work.weighting
      )
    }

    private func configureAnalysisPipelineIfNeeded(
      analysisWork: AnalysisWork?,
      flags: AnalysisFlags
    ) {
      guard !flags.isEmpty else { return }

      var resolvedTimeDomain = analysisWork?.timeDomain
      if (flags.contains(.timeDomain) || flags.contains(.beat)) && resolvedTimeDomain == nil {
        resolvedTimeDomain = configuration.amplitudeAnalyzerConfiguration
        log.warning("Analysis work requested without a timeDomain configuration; using defaults.")
      }

      var resolvedFrequencyWork: FrequencyDomainWork?
      if flags.contains(.frequencyDomain) {
        if let frequencyWork = analysisWork?.frequencyDomain {
          resolvedFrequencyWork = normalizedFrequencyWork(frequencyWork)
        } else if let frequencyConfig = configuration.frequencyAnalyzerConfiguration {
          resolvedFrequencyWork = FrequencyDomainWork(
            configuration: frequencyConfig,
            bucketMode: configuration.bucketMode,
            weighting: configuration.frequencyWeighting
          )
          log.warning(
            "Analysis frequency domain requested without a configuration; using defaults."
          )
        }
      }

      var resolvedBeatDetection: BeatDetectionConfiguration?
      if flags.contains(.beat) {
        resolvedBeatDetection =
          analysisWork?.beatDetection ?? configuration.beatDetectionConfiguration
      }

      let newConfig = AnalysisConfig(
        timeDomain: resolvedTimeDomain,
        frequencyDomain: resolvedFrequencyWork,
        beatDetection: resolvedBeatDetection
      )

      let needsRebuild = analysisPipeline == nil || analysisConfig != newConfig
      guard needsRebuild else { return }

      analysisEnabledAtomic.store(false, ordering: .relaxed)
      analysisTimer?.cancel()
      analysisTimer = nil
      processingQueue.sync {}

      analysisPipeline = AnalysisPipeline(config: newConfig, sampleRate: configuration.sampleRate)
      analysisConfig = newConfig

      if let analyzer = analysisPipeline?.frequencyAnalyzer {
        frequencyLabels = analyzer.getFrequencyLabels()
      } else {
        frequencyLabels.removeAll()
      }

      analysisEnabledAtomic.store(true, ordering: .relaxed)
    }

    private func updateAnalysisTimerIfNeeded() {
      analysisTimer?.cancel()
      analysisTimer = nil

      guard isActiveAtomic.load(ordering: .relaxed) else { return }
      guard analysisEnabledAtomic.load(ordering: .relaxed) else { return }
      guard let updateRateHz = analysisUpdateRateHz else { return }

      let interval = 1.0 / max(updateRateHz, 1)
      let timer = DispatchSource.makeTimerSource(queue: processingQueue)
      timer.schedule(deadline: .now(), repeating: interval)
      timer.setEventHandler { [weak self] in
        self?.updateVisualizations()
      }
      timer.resume()
      analysisTimer = timer
    }

    private func updateLodPublishTimerIfNeeded() {
      lodPublishTimer?.cancel()
      lodPublishTimer = nil

      guard isActiveAtomic.load(ordering: .relaxed) else { return }
      guard let rateHz = lodPublishRateHz else { return }

      let interval = 1.0 / max(rateHz, 1)
      let timer = DispatchSource.makeTimerSource(queue: lodPublishQueue)
      timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
      timer.setEventHandler { [weak self] in
        self?.publishLODSnapshot()
      }
      timer.resume()
      lodPublishTimer = timer
    }

    private func updateAudioBuffer(_ data: UnsafeBufferPointer<Float>) {
      guard !data.isEmpty else { return }
      unsafe analysisPipeline?.ringBuffer.write(data)
    }

    private func updateVisualizations() {
      guard analysisEnabledAtomic.load(ordering: .relaxed),
        let pipeline = analysisPipeline
      else { return }

      let flags = AnalysisFlags(rawValue: analysisFlagsAtomic.load(ordering: .relaxed))
      guard !flags.isEmpty else { return }

      let desiredSamples = pipeline.maxVisualizationSamples
      var readCount = 0

      unsafe pipeline.readScratchBuffer.withUnsafeMutableBufferPointer { bufferPointer in
        guard let base = bufferPointer.baseAddress else { return }
        let limitedBuffer = unsafe UnsafeMutableBufferPointer(start: base, count: desiredSamples)
        readCount = unsafe pipeline.ringBuffer.read(into: limitedBuffer)
      }

      guard readCount > 0 else { return }

      let sampleRate = currentSampleRate
      let latestEnd = latestEndSampleTimeAtomic.load(ordering: .relaxed)
      let lastEnd = lastBeatUpdateEndSampleTimeAtomic.exchange(latestEnd, ordering: .relaxed)
      let deltaSamples = max(Int64(0), latestEnd - lastEnd)
      let deltaTime = Double(deltaSamples) / max(sampleRate, 1)
      let audioChunk = Array(pipeline.readScratchBuffer.prefix(readCount))

      var amplitudeResult: AmplitudeData?
      if flags.contains(.timeDomain) || flags.contains(.beat),
        let amplitudeAnalyzer = pipeline.amplitudeAnalyzer
      {
        amplitudeResult = amplitudeAnalyzer.processAmplitudeData(audioChunk)
      }

      var spectrumResult: SpectrumData?
      if flags.contains(.frequencyDomain), let frequencyAnalyzer = pipeline.frequencyAnalyzer {
        spectrumResult = frequencyAnalyzer.processFrequencyData(audioChunk)
      }

      var newTimeDomain: TimeDomainData?
      if flags.contains(.timeDomain), let amplitudeResult {
        newTimeDomain = TimeDomainData(
          samples: amplitudeResult.amplitudes,
          peaks: amplitudeResult.peaks,
          rmsLevel: amplitudeResult.rms,
          level: amplitudeResult.overallLevel
        )
      }

      var newFrequencyDomain: FrequencyDomainData?
      var newSpectrumPeakHold: [Float] = []
      if flags.contains(.frequencyDomain),
        let spectrumResult,
        let bucketer = pipeline.frequencyBucketer
      {
        let buckets = bucketer.bucket(
          spectrum: spectrumResult.spectrum,
          frequencies: spectrumResult.frequencies
        )

        newFrequencyDomain = FrequencyDomainData(
          buckets: buckets,
          rawSpectrum: spectrumResult.spectrum,
          frequencies: spectrumResult.frequencies,
          peakFrequency: spectrumResult.peakFrequency,
          spectralCentroid: spectrumResult.spectralCentroid
        )

        let decayRate = pipeline.peakHoldDecayRate
        newSpectrumPeakHold = updateSpectrumPeaks(
          current: spectrumPeakHold,
          newSpectrum: spectrumResult.spectrum,
          decayRate: decayRate
        )
      }

      var beatInfo: BeatInfo?
      if flags.contains(.beat), let beatDetector = pipeline.beatDetector {
        let rmsLevel = amplitudeResult?.rms ?? 0
        beatInfo = beatDetector.analyze(
          spectrum: spectrumResult?.spectrum ?? [],
          rmsLevel: rmsLevel,
          deltaTime: deltaTime
        )
      }

      let subscribers = subscriberSnapshots()
      DispatchQueue.main.async {
        if let newTimeDomain {
          self.timeDomain = newTimeDomain
          self.deliver(.timeDomain(newTimeDomain), to: subscribers)
        }

        if let newFrequencyDomain {
          self.frequencyDomain = newFrequencyDomain
          self.deliver(.frequencyDomain(newFrequencyDomain), to: subscribers)
          self.spectrumPeakHold = newSpectrumPeakHold
        }

        if let beatInfo {
          self.beat = beatInfo
          self.deliver(.beat(beatInfo), to: subscribers)
        }
      }
    }

    private func publishLODSnapshot() {
      guard lodEnabledAtomic.load(ordering: .relaxed) else { return }
      let snapshot = unsafe lodProcessor?.withCurrentLODSnapshotRef { $0 }
      let subscribers = subscriberSnapshots()
      deliver(.lodSnapshotBackground(snapshot), to: subscribers)
      DispatchQueue.main.async {
        self.deliver(.lodSnapshot(snapshot), to: subscribers)
      }
    }

    private func updateSpectrumPeaks(
      current: [Float],
      newSpectrum: [Float],
      decayRate: Float
    ) -> [Float] {
      var peaks: [Float]
      if current.count != newSpectrum.count {
        peaks = Array(repeating: 0.0, count: newSpectrum.count)
      } else {
        peaks = current
      }

      for index in newSpectrum.indices {
        let decayed = max(0.0, peaks[index] - decayRate)
        peaks[index] = max(decayed, newSpectrum[index])
      }

      return peaks
    }
  }

  extension AudioVisualizationEngine: BufferReceiver {
    public typealias T = Float

    nonisolated public func processBuffer(_ data: UnsafeBufferPointer<Float>) {
      guard wantsActiveAtomic.load(ordering: .relaxed), data.count > 0 else { return }
      let startSampleTime = fallbackSampleTimeAtomic.load(ordering: .relaxed)
      fallbackSampleTimeAtomic.wrappingIncrement(by: Int64(data.count), ordering: .relaxed)
      let timing = BufferTiming(
        sampleTime: startSampleTime,
        sampleRate: configuration.sampleRate
      )
      unsafe processBuffer(data, timing: timing)
    }

    nonisolated public func processBuffer(
      _ data: UnsafeBufferPointer<Float>,
      timing: BufferTiming
    ) {
      guard wantsActiveAtomic.load(ordering: .relaxed), data.count > 0 else { return }
      latestEndSampleTimeAtomic.store(
        timing.sampleTime + Int64(data.count),
        ordering: .relaxed
      )
      latestSampleRateBitsAtomic.store(timing.sampleRate.bitPattern, ordering: .relaxed)

      guard isActiveAtomic.load(ordering: .relaxed) else { return }
      if analysisEnabledAtomic.load(ordering: .relaxed) {
        unsafe self.updateAudioBuffer(data)
      }

      if lodEnabledAtomic.load(ordering: .relaxed) {
        unsafe lodProcessor?.process(data)
      }

      let subscribers = subscriberSnapshots()
      DispatchQueue.main.async {
        self.latestBufferTiming = timing
        self.deliver(.latestBufferTiming(timing), to: subscribers)
      }
    }

    nonisolated public func endBufferTask() {
      wantsActiveAtomic.store(false, ordering: .relaxed)
      Task { @MainActor [weak self] in
        self?.stopVisualization()
      }
    }
  }

  // MARK: - Configuration Extensions

  extension AudioVisualizationEngine.Configuration {
    /// Returns a copy of this configuration with a different sample rate.
    public func withSampleRate(_ sampleRate: Double) -> Self {
      AudioVisualizationEngine.Configuration(
        amplitudeWindowSize: amplitudeWindowSize,
        spectrumSize: spectrumSize,
        analysisUpdateRateHz: analysisUpdateRateHz,
        smoothingFactor: smoothingFactor,
        sampleRate: sampleRate,
        amplitudeAnalyzerConfiguration: amplitudeAnalyzerConfiguration,
        frequencyAnalyzerConfiguration: frequencyAnalyzerConfiguration,
        bucketMode: bucketMode,
        frequencyWeighting: frequencyWeighting,
        beatDetectionConfiguration: beatDetectionConfiguration
      )
    }

    /// A configuration optimized for real-time recording visualization.
    public static let realTimeRecording = AudioVisualizationEngine.Configuration(
      amplitudeWindowSize: 256,
      spectrumSize: 128,
      analysisUpdateRateHz: 60.0,
      smoothingFactor: 0.4,
      bucketMode: .mel(bucketCount: 24),
      beatDetectionConfiguration: .default
    )

    /// A low-power configuration for conserving battery.
    public static let lowPower = AudioVisualizationEngine.Configuration(
      amplitudeWindowSize: 128,
      spectrumSize: 64,
      analysisUpdateRateHz: 30.0,
      smoothingFactor: 0.5,
      bucketMode: .mel(bucketCount: 16),
      beatDetectionConfiguration: .lowSensitivity
    )

    /// A high-quality configuration for detailed analysis.
    public static let highQuality = AudioVisualizationEngine.Configuration(
      amplitudeWindowSize: 1024,
      spectrumSize: 512,
      analysisUpdateRateHz: 60.0,
      smoothingFactor: 0.2,
      bucketMode: .mel(bucketCount: 32),
      beatDetectionConfiguration: .highSensitivity
    )
  }

  extension AudioVisualizationEngine: VisualizationDriving {}

#endif
