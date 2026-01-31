#if canImport(AVFAudio)
  import Atomics
  import AVFAudio
  import Foundation
  import SystemLog
  import Tools

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
  /// - ``updateBucketMode(_:)``
  /// - ``updateBeatDetectionConfiguration(_:)``
  ///
  /// This type is `@unchecked Sendable` because it is used as a real-time audio callback
  /// target (via `BufferReceiver`) and is passed across concurrency boundaries.
  ///
  /// ## Safety
  /// - The audio thread only calls `processBuffer(_:)` (which uses atomics and does not
  ///   touch `@Observable` state directly).
  /// - Observable state (`timeDomain` / `frequencyDomain` / `beat`) is published from the
  ///   main queue.
  /// - Optional LOD processing must be configured before the instance is attached as a
  ///   buffer receiver; it must not be enabled/disabled while active.
  @Observable
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

    // MARK: Legacy API (for backward compatibility)

    /// An array of floating-point values representing the audio waveform data.
    /// Normalized to the range `[0.0, 1.0]`.
    /// - Note: This is a convenience accessor for `timeDomain.samples`.
    public var amplitudeData: [Float] {
      get { timeDomain.samples }
      set { timeDomain.samples = newValue }
    }

    /// An array of floating-point values representing the audio spectrum data.
    /// Normalized to the range `[0.0, 1.0]`.
    /// - Note: This is a convenience accessor for `frequencyDomain.rawSpectrum`.
    public var spectrumData: [Float] {
      get { frequencyDomain.rawSpectrum }
      set { frequencyDomain.rawSpectrum = newValue }
    }

    /// Frequencies corresponding to the current spectrum data.
    /// - Note: This is a convenience accessor for `frequencyDomain.frequencies`.
    public var spectrumFrequencies: [Float] {
      get { frequencyDomain.frequencies }
      set { frequencyDomain.frequencies = newValue }
    }

    /// Peak-hold values for the spectrum with decay applied.
    public var spectrumPeakHold: [Float] = []

    /// Peak amplitudes with decay applied by the amplitude analyzer.
    /// - Note: This is a convenience accessor for `timeDomain.peaks`.
    public var peakAmplitudes: [Float] {
      get { timeDomain.peaks }
      set { timeDomain.peaks = newValue }
    }

    /// Rolling RMS level of the incoming audio stream.
    /// - Note: This is a convenience accessor for `timeDomain.rmsLevel`.
    public var rmsLevel: Float {
      get { timeDomain.rmsLevel }
      set { timeDomain.rmsLevel = newValue }
    }

    /// Overall amplitude level reported by the analyzer.
    /// - Note: This is a convenience accessor for `timeDomain.level`.
    public var overallLevel: Float {
      get { timeDomain.level }
      set { timeDomain.level = newValue }
    }

    /// Brightness metric derived from the spectrum analyzer.
    /// - Note: This is a convenience accessor for `frequencyDomain.spectralCentroid`.
    public var spectralCentroid: Float {
      get { frequencyDomain.spectralCentroid }
      set { frequencyDomain.spectralCentroid = newValue }
    }

    /// Frequency (Hz) of the strongest band in the latest spectrum frame.
    /// - Note: This is a convenience accessor for `frequencyDomain.peakFrequency`.
    public var peakFrequency: Float {
      get { frequencyDomain.peakFrequency }
      set { frequencyDomain.peakFrequency = newValue }
    }

    /// Cached frequency labels for UI overlays.
    public var frequencyLabels: [(frequency: Float, label: String)] = []

    /// A Boolean value that indicates whether the visualization engine is currently active.
    public var isActive = false
    private let isActiveAtomic = ManagedAtomic<Bool>(false)
    private let wantsActiveAtomic = ManagedAtomic<Bool>(false)
    private let isForegroundAtomic = ManagedAtomic<Bool>(true)
    private let hasConsumerAtomic = ManagedAtomic<Bool>(false)
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
      /// The number of times per second at which the visualization should be updated.
      public let updateRateHz: Double
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
      ///   - updateRateHz: The rate at which the visualization should be updated, in Hertz. Defaults to 60.0.
      ///   - smoothingFactor: A factor that controls the amount of smoothing applied. Defaults to 0.3.
      ///   - sampleRate: The nominal sample rate of the source audio. Defaults to 44100.0.
      ///   - bucketMode: The frequency bucketing mode. Defaults to MEL scale with 24 buckets.
      ///   - frequencyWeighting: Perceptual weighting applied to frequency buckets. Defaults to none.
      ///   - beatDetectionConfiguration: Beat detection configuration. Defaults to standard settings.
      public init(
        amplitudeWindowSize: Int = 512,
        spectrumSize: Int = 256,
        updateRateHz: Double = 60.0,
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
        self.updateRateHz = updateRateHz
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
    /// Enable with `enableMultiBandLOD(configuration:)`.
    private var lodProcessor: MultiBandLODProcessor?
    private var lodConfig: MultiBandLODConfiguration?
    private var legacyLodWork: LODWork?

    /// Current multi-band LOD snapshot for GPU rendering (creates a copy).
    /// Returns nil if multi-band LOD is not enabled.
    /// For zero-copy access, use `multiBandLODRef` instead.
    public var multiBandLOD: MultiBandLODSnapshot? {
      lodProcessor?.snapshot()
    }

    /// Zero-copy reference to current multi-band LOD data for GPU rendering.
    /// Returns nil if multi-band LOD is not enabled.
    ///
    /// This returns a reference to pre-allocated buffers without any memory
    /// allocation or copying. The reference is safe to use for rendering because
    /// triple-buffering guarantees the audio thread won't write to this data.
    public var multiBandLODRef: LODSnapshotRef? {
      lodProcessor?.snapshotRef()
    }

    /// Whether multi-band LOD processing is enabled.
    public var isMultiBandLODEnabled: Bool {
      lodProcessor != nil
    }

    // MARK: - Private Properties

    private let configuration: Configuration

    private let processingQueue = DispatchQueue(
      label: "audio-visualization",
      qos: .userInteractive
    )

    private struct ConsumerState {
      var consumerId: ObjectIdentifier?
      var work: VisualizationWork
      var sinks: VisualizationSinks

      init(
        consumerId: ObjectIdentifier? = nil,
        work: VisualizationWork = .none,
        sinks: VisualizationSinks = .empty
      ) {
        self.consumerId = consumerId
        self.work = work
        self.sinks = sinks
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

    private final class AnalysisPipeline {
      let amplitudeAnalyzer: AmplitudeAnalyzer?
      let frequencyAnalyzer: FrequencyAnalyzer?
      let frequencyBucketer: FrequencyBucketer?
      let beatDetector: BeatDetector?
      let frequencySampleCount: Int
      let peakHoldDecayRate: Float
      let ringBuffer: RingBuffer<Float>
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
        self.ringBuffer = RingBuffer<Float>(capacity: ringCapacity)
        self.readScratchBuffer = Array(repeating: 0.0, count: resolvedMaxSamples)
      }
    }

    private let consumerLock = NSLock()
    private var consumerState = ConsumerState()
    private let analysisFlagsAtomic = ManagedAtomic<Int>(0)

    private var analysisConfig: AnalysisConfig?
    private var analysisPipeline: AnalysisPipeline?
    private var analysisUpdateRateHz: Double?
    private var lodPublishRateHz: Double?

    private var analysisTimer: DispatchSourceTimer?
    private var lodPublishTimer: DispatchSourceTimer?

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

    /// Registers a visualization consumer and applies its declared work and sinks.
    @MainActor
    public func register(consumer: VisualizationConsumer) {
      let consumerId = ObjectIdentifier(consumer)
      let work = consumer.work
      let sinks = consumer.sinks

      updateConsumerState(consumerId: consumerId, work: work, sinks: sinks)
      hasConsumerAtomic.store(true, ordering: .relaxed)
      applyWork(work, sinks: sinks)
      updateProcessingState()
    }

    /// Unregisters a visualization consumer if it is currently active.
    @MainActor
    public func unregister(consumer: VisualizationConsumer) {
      let consumerId = ObjectIdentifier(consumer)
      let removed = clearConsumerIfMatching(consumerId)
      guard removed else { return }
      hasConsumerAtomic.store(false, ordering: .relaxed)
      applyWork(.none, sinks: .empty)
      updateProcessingState()
    }

    @available(*, deprecated, message: "Use register(consumer:) instead.")
    public func visualizationConsumerDidAppear() {
      hasConsumerAtomic.store(true, ordering: .relaxed)
      updateProcessingState()
    }

    @available(*, deprecated, message: "Use unregister(consumer:) instead.")
    public func visualizationConsumerDidDisappear() {
      hasConsumerAtomic.store(false, ordering: .relaxed)
      updateProcessingState()
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
      analysisPipeline?.ringBuffer.clearIndices()
      fallbackSampleTimeAtomic.store(0, ordering: .relaxed)
      latestEndSampleTimeAtomic.store(0, ordering: .relaxed)
      latestSampleRateBitsAtomic.store(configuration.sampleRate.bitPattern, ordering: .relaxed)
      lodProcessor?.reset()

      log.info("Audio visualization stopped")
    }

    private func updateProcessingState() {
      let wantsActive = wantsActiveAtomic.load(ordering: .relaxed)
      let isForeground = isForegroundAtomic.load(ordering: .relaxed)
      let hasConsumer = hasConsumerAtomic.load(ordering: .relaxed)

      let shouldBeActive = wantsActive && isForeground && hasConsumer
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

    /// Updates the frequency bucket mode.
    ///
    /// - Parameter mode: The new bucketing mode to use.
    @available(*, deprecated, message: "Use VisualizationWork instead.")
    public func updateBucketMode(_ mode: FrequencyBucketMode) {
      analysisPipeline?.frequencyBucketer?.updateMode(mode)
    }

    /// Updates the beat detection configuration.
    ///
    /// - Parameter configuration: The new beat detection configuration.
    @available(*, deprecated, message: "Use VisualizationWork instead.")
    public func updateBeatDetectionConfiguration(_ configuration: BeatDetectionConfiguration) {
      analysisPipeline?.beatDetector?.updateConfiguration(configuration)
    }

    // MARK: - Multi-Band LOD

    /// Enables multi-band LOD processing for Metal visualization.
    ///
    /// When enabled, audio samples are also processed through a multi-band filter
    /// bank and downsampled for efficient GPU rendering. Access the data via
    /// the `multiBandLOD` property.
    ///
    /// - Parameter configuration: LOD processing configuration.
    public func enableMultiBandLOD(configuration: MultiBandLODConfiguration = .default) {
      let resolvedSampleRate = max(Int(self.configuration.sampleRate.rounded()), 1)
      let resolvedConfig = MultiBandLODConfiguration(
        bandCount: configuration.bandCount,
        lodRatio: configuration.lodRatio,
        bufferSeconds: configuration.bufferSeconds,
        sampleRate: resolvedSampleRate,
        crossoverMode: configuration.crossoverMode,
        snapshotSwapInterval: configuration.snapshotSwapInterval,
        rawBufferLengthOverride: configuration.rawBufferLengthOverride
      )
      legacyLodWork = LODWork(configuration: resolvedConfig)
      let snapshot = consumerSnapshot()
      applyWork(snapshot.work, sinks: snapshot.sinks)
      log.info("Multi-band LOD enabled: \(configuration.bandCount, privacy: .public) bands")
    }

    /// Disables multi-band LOD processing.
    public func disableMultiBandLOD() {
      legacyLodWork = nil
      let snapshot = consumerSnapshot()
      applyWork(snapshot.work, sinks: snapshot.sinks)
      log.info("Multi-band LOD disabled")
    }

    /// Resets the multi-band LOD buffers.
    ///
    /// Call this when starting a new recording to clear history.
    public func resetMultiBandLOD() {
      lodProcessor?.reset()
    }

    /// Processes an `AVAudioPCMBuffer` for visualization.
    ///
    /// - Parameter buffer: The audio buffer to process.
    public func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
      guard isActiveAtomic.load(ordering: .relaxed),
        let floatData = buffer.floatChannelData?[0]
      else { return }

      let bufferPointer = UnsafeBufferPointer(
        start: floatData,
        count: Int(buffer.frameLength)
      )
      processBuffer(bufferPointer)
    }

    // MARK: - Private Methods
    private func updateConsumerState(
      consumerId: ObjectIdentifier,
      work: VisualizationWork,
      sinks: VisualizationSinks
    ) {
      consumerLock.lock()
      consumerState.consumerId = consumerId
      consumerState.work = work
      consumerState.sinks = sinks
      consumerLock.unlock()
    }

    private func clearConsumerIfMatching(_ consumerId: ObjectIdentifier) -> Bool {
      consumerLock.lock()
      defer { consumerLock.unlock() }
      guard consumerState.consumerId == consumerId else { return false }
      consumerState = ConsumerState()
      return true
    }

    private func consumerSnapshot() -> ConsumerState {
      consumerLock.lock()
      let snapshot = consumerState
      consumerLock.unlock()
      return snapshot
    }

    private func sinksSnapshot() -> VisualizationSinks {
      consumerLock.lock()
      let sinks = consumerState.sinks
      consumerLock.unlock()
      return sinks
    }

    private func applyWork(_ work: VisualizationWork, sinks: VisualizationSinks) {
      let resolvedLodWork = work.lod ?? legacyLodWork
      if resolvedLodWork != nil, sinks.lodSnapshot == nil {
        log.warning("VisualizationWork.lod requested without a lodSnapshot sink.")
      }
      let wantsLod = resolvedLodWork != nil && sinks.lodSnapshot != nil
      lodPublishRateHz = wantsLod ? resolvedLodWork?.publishRateHz : nil

      if let lodWork = resolvedLodWork, wantsLod {
        let resolvedConfig = normalizedLODConfig(lodWork.configuration)
        if lodConfig != resolvedConfig {
          lodEnabledAtomic.store(false, ordering: .relaxed)
          lodProcessor = MultiBandLODProcessor(configuration: resolvedConfig)
          lodConfig = resolvedConfig
        }
        lodEnabledAtomic.store(true, ordering: .relaxed)
      } else {
        lodEnabledAtomic.store(false, ordering: .relaxed)
        lodProcessor = nil
        lodConfig = nil
      }

      var flags: AnalysisFlags = []
      if let analysisWork = work.analysis {
        let wantsBeat = analysisWork.beatDetection != nil && sinks.beat != nil
        let wantsTimeOutput = analysisWork.timeDomain != nil && sinks.timeDomain != nil
        let wantsFrequencyOutput =
          analysisWork.frequencyDomain != nil && sinks.frequencyDomain != nil

        let wantsTimeAnalysis = wantsTimeOutput || wantsBeat
        if analysisWork.timeDomain != nil || analysisWork.beatDetection != nil {
          if wantsTimeAnalysis {
            flags.insert(.timeDomain)
          } else {
            log.warning("VisualizationWork.timeDomain requested without any time-domain sinks.")
          }
        }

        let wantsFrequencyAnalysis =
          analysisWork.frequencyDomain != nil && (wantsFrequencyOutput || wantsBeat)
        if analysisWork.frequencyDomain != nil {
          if wantsFrequencyAnalysis {
            flags.insert(.frequencyDomain)
          } else {
            log.warning(
              "VisualizationWork.frequencyDomain requested without any frequency sinks."
            )
          }
        }

        if wantsBeat {
          flags.insert(.beat)
        } else if analysisWork.beatDetection != nil {
          log.warning("VisualizationWork.beatDetection requested without a beat sink.")
        }
      }

      analysisFlagsAtomic.store(flags.rawValue, ordering: .relaxed)
      analysisEnabledAtomic.store(!flags.isEmpty, ordering: .relaxed)
      analysisUpdateRateHz =
        flags.isEmpty
        ? nil
        : (work.analysis?.updateRateHz ?? configuration.updateRateHz)

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
      let timer = DispatchSource.makeTimerSource(queue: processingQueue)
      timer.schedule(deadline: .now(), repeating: interval)
      timer.setEventHandler { [weak self] in
        self?.publishLODSnapshot()
      }
      timer.resume()
      lodPublishTimer = timer
    }

    private func updateAudioBuffer(_ data: UnsafeBufferPointer<Float>) {
      guard !data.isEmpty else { return }
      analysisPipeline?.ringBuffer.write(data)
    }

    private func updateVisualizations() {
      guard analysisEnabledAtomic.load(ordering: .relaxed),
        let pipeline = analysisPipeline
      else { return }

      let flags = AnalysisFlags(rawValue: analysisFlagsAtomic.load(ordering: .relaxed))
      guard !flags.isEmpty else { return }

      let desiredSamples = pipeline.maxVisualizationSamples
      var readCount = 0

      pipeline.readScratchBuffer.withUnsafeMutableBufferPointer { bufferPointer in
        guard let base = bufferPointer.baseAddress else { return }
        let limitedBuffer = UnsafeMutableBufferPointer(start: base, count: desiredSamples)
        readCount = pipeline.ringBuffer.read(into: limitedBuffer)
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

      let sinks = sinksSnapshot()
      let shouldPublishTimeDomain = sinks.timeDomain != nil
      let shouldPublishFrequencyDomain = sinks.frequencyDomain != nil
      let shouldPublishBeat = sinks.beat != nil
      DispatchQueue.main.async {
        if let newTimeDomain, shouldPublishTimeDomain {
          self.timeDomain = newTimeDomain
          sinks.timeDomain?(newTimeDomain)
        }

        if let newFrequencyDomain, shouldPublishFrequencyDomain {
          self.frequencyDomain = newFrequencyDomain
          sinks.frequencyDomain?(newFrequencyDomain)
          self.spectrumPeakHold = newSpectrumPeakHold
        }

        if let beatInfo, shouldPublishBeat {
          self.beat = beatInfo
          sinks.beat?(beatInfo)
        }
      }
    }

    private func publishLODSnapshot() {
      guard lodEnabledAtomic.load(ordering: .relaxed) else { return }
      let snapshot = lodProcessor?.snapshotRef()
      let sinks = sinksSnapshot()
      guard sinks.lodSnapshot != nil else { return }
      DispatchQueue.main.async {
        sinks.lodSnapshot?(snapshot)
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
      processBuffer(data, timing: timing)
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
        self.updateAudioBuffer(data)
      }

      if lodEnabledAtomic.load(ordering: .relaxed) {
        lodProcessor?.process(data)
      }

      let sinks = sinksSnapshot()
      DispatchQueue.main.async {
        self.latestBufferTiming = timing
        sinks.latestBufferTiming?(timing)
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
        updateRateHz: updateRateHz,
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
      updateRateHz: 60.0,
      smoothingFactor: 0.4,
      bucketMode: .mel(bucketCount: 24),
      beatDetectionConfiguration: .default
    )

    /// A low-power configuration for conserving battery.
    public static let lowPower = AudioVisualizationEngine.Configuration(
      amplitudeWindowSize: 128,
      spectrumSize: 64,
      updateRateHz: 30.0,
      smoothingFactor: 0.5,
      bucketMode: .mel(bucketCount: 16),
      beatDetectionConfiguration: .lowSensitivity
    )

    /// A high-quality configuration for detailed analysis.
    public static let highQuality = AudioVisualizationEngine.Configuration(
      amplitudeWindowSize: 1024,
      spectrumSize: 512,
      updateRateHz: 60.0,
      smoothingFactor: 0.2,
      bucketMode: .mel(bucketCount: 32),
      beatDetectionConfiguration: .highSensitivity
    )
  }

#endif
