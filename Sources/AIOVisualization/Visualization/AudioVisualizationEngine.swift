// © GoodHatsLLC

#if canImport(AVFAudio)
  public import AIOContracts
  import AIOSupport
  import Atomics
  public import AudioSignals
  public import AVFAudio
  import Foundation
  public import Observation
  import os
  import QuartzCore
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
    private let wantsActiveAtomic = ManagedAtomic<Bool>(false)
    private let isForegroundAtomic = ManagedAtomic<Bool>(true)
    private let hasSubscriberAtomic = ManagedAtomic<Bool>(false)

    /// Most recently received buffer timing (published from the main queue).
    public var latestBufferTiming: BufferTiming?

    /// A monotonically-increasing audio clock derived from `BufferTiming.sampleTime`.
    ///
    /// This clock advances even when visualization processing is gated off by consumer visibility,
    /// so the app can rely on sample-accurate time while recording continues in the background.
    public nonisolated var currentTimeSeconds: TimeInterval {
      processor.currentTimeSeconds
    }

    /// Current sample rate derived from the latest `BufferTiming` seen by this engine.
    ///
    /// Falls back to the configured sample rate if no timing has been received yet.
    public nonisolated var currentSampleRate: Double {
      processor.currentSampleRate
    }

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
        sampleRate: Double = 44100.0,
        amplitudeAnalyzerConfiguration: AmplitudeAnalyzer.Configuration? = nil,
        frequencyAnalyzerConfiguration: FrequencyAnalyzer.Configuration? = nil,
        bucketMode: FrequencyBucketMode = .default,
        frequencyWeighting: FrequencyWeighting = .none,
        beatDetectionConfiguration: BeatDetectionConfiguration = .default,
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
            noiseFloor: 0.001,
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
            windowType: .hann,
          )
        } else {
          self.frequencyAnalyzerConfiguration = nil
        }
      }
    }

    // MARK: - Multi-Band LOD (Optional)

    // Multi-band Level-of-Detail processor for Metal visualization.
    // Configured through `VisualizationWork.lod` from active subscribers.

    /// Current multi-band LOD snapshot for GPU rendering (creates a copy).
    /// Returns nil if multi-band LOD is not enabled.
    /// For frame-scoped zero-copy access, use `withCurrentLODSnapshotRef(_:)`.
    public var multiBandLOD: MultiBandLODSnapshot? {
      processor.multiBandLOD
    }

    /// Provides frame-scoped zero-copy access to current LOD data.
    ///
    /// Returns `nil` when multi-band LOD is not enabled.
    public func withCurrentLODSnapshotRef<R>(_ body: (LODSnapshotRef) -> R) -> R? {
      processor.withCurrentLODSnapshotRef(body)
    }

    /// Whether multi-band LOD processing is enabled.
    public var isMultiBandLODEnabled: Bool {
      processor.isMultiBandLODEnabled
    }

    // MARK: - Private Properties

    private let configuration: Configuration

    private let hub: VisualizationHub
    private let callbackTasks = AsyncTaskRunner()
    @ObservationIgnored private var processor: VisualizationProcessor!

    // MARK: - Initialization

    /// Creates a new audio visualization engine with the specified configuration.
    ///
    /// - Parameter configuration: The configuration to use for the visualization engine.
    public init(configuration: Configuration = Configuration()) {
      self.configuration = configuration
      hub = VisualizationHub(configuration: configuration)
      processor = makeProcessor()
    }

    deinit {
      callbackTasks.cancelAllNow()
      shutdownProcessing(publishActiveState: false)
    }

    private func makeProcessor() -> VisualizationProcessor {
      VisualizationProcessor(
        configuration: configuration,
        callbacks: .init(
          onAnalysisFrame: { [weak self] frame in
            guard let self else { return }
            let dispatcher = self.hub.dispatcher()
            VisualizationMainDelivery.async { [weak self] in
              guard let self else { return }
              if let newTimeDomain = frame.timeDomain {
                self.timeDomain = newTimeDomain
                dispatcher.deliver(.timeDomain(newTimeDomain))
              }

              if let newFrequencyDomain = frame.frequencyDomain {
                self.frequencyDomain = newFrequencyDomain
                dispatcher.deliver(.frequencyDomain(newFrequencyDomain))
                self.spectrumPeakHold = frame.spectrumPeakHold
              }

              if let beatInfo = frame.beat {
                self.beat = beatInfo
                dispatcher.deliver(.beat(beatInfo))
              }
            }
          },
          onLatestBufferTiming: { [weak self] timing in
            guard let self else { return }
            let dispatcher = self.hub.dispatcher()
            VisualizationMainDelivery.async { [weak self] in
              guard let self else { return }
              self.latestBufferTiming = timing
              dispatcher.deliver(.latestBufferTiming(timing))
            }
          },
          onLODSnapshot: { [weak self] in
            guard let self else { return }
            let dispatcher = self.hub.dispatcher()
            dispatcher.deliver(.lodSnapshotBackground)
            VisualizationMainDelivery.async {
              dispatcher.deliver(.lodSnapshot)
            }
          },
          onFrequencyLabelsChanged: { [weak self] labels in
            VisualizationMainDelivery.async { [weak self] in
              self?.frequencyLabels = labels
            }
          },
        ),
      )
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
      handler: @escaping (VisualizationEvent) -> Void,
    ) -> VisualizationSubscription {
      let id = UUID()
      let demand = hub.addSubscriber(
        id: id,
        request: request,
        eventHandler: handler,
      )
      applyDemandResolution(demand)
      updateProcessingState()

      return VisualizationSubscription { [weak self] in
        self?.removeSubscription(id: id)
      }
    }

    /// Subscribes to visualization events via a sink object.
    @MainActor
    public func subscribe(
      request: VisualizationRequest,
      sink: any VisualizationSink,
    ) -> VisualizationSubscription {
      let eventTasks = AsyncTaskRunner()
      let subscription = subscribe(request: request) { [eventTasks, weak sink] event in
        guard let sink else { return }
        eventTasks.run { [weak sink] in
          await MainActor.run {
            sink?.receive(event)
          }
        }
      }

      return VisualizationSubscription {
        subscription.cancel()
        eventTasks.cancelAllNow()
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
      shutdownProcessing(publishActiveState: true)

      // Clear data
      timeDomain = .empty
      frequencyDomain = .empty
      beat = .empty
      spectrumPeakHold.removeAll()
      latestBufferTiming = nil

      log.info("Audio visualization stopped")
    }

    #if DEBUG
      @MainActor
      public func debugPublishLODSnapshotForTesting() {
        processor.publishLODSnapshotForTesting()
      }

      @MainActor
      public func debugDrainVisualizationDeliveryForTesting() async {
        await VisualizationMainDelivery.drainForTesting()
        await callbackTasks.drain()
      }
    #endif

    private func shutdownProcessing(publishActiveState: Bool) {
      wantsActiveAtomic.store(false, ordering: .relaxed)
      guard let processor else { return }
      if processor.setActive(false), publishActiveState {
        isActive = false
      }
      processor.reset()
    }

    private func updateProcessingState() {
      let wantsActive = wantsActiveAtomic.load(ordering: .relaxed)
      let isForeground = isForegroundAtomic.load(ordering: .relaxed)
      let hasSubscriber = hasSubscriberAtomic.load(ordering: .relaxed)

      let shouldBeActive = wantsActive && isForeground && hasSubscriber
      guard processor.setActive(shouldBeActive) else { return }
      isActive = shouldBeActive
    }

    /// Processes an `AVAudioPCMBuffer` for visualization.
    ///
    /// - Parameter buffer: The audio buffer to process.
    public func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
      guard wantsActiveAtomic.load(ordering: .relaxed) else { return }
      processor.processAudioBuffer(buffer)
    }

    // MARK: - Private Methods

    private func removeSubscription(id: UUID) {
      guard let demand = hub.removeSubscriber(id: id) else { return }
      applyDemandResolution(demand)
      updateProcessingState()
    }

    private func applyDemandResolution(_ demand: VisualizationHub.DemandResolution) {
      hasSubscriberAtomic.store(demand.hasSubscribers, ordering: .relaxed)
      processor.apply(work: demand.work)
    }
  }

  extension AudioVisualizationEngine: BufferReceiver {
    public typealias T = Float

    public nonisolated func processBuffer(_ data: UnsafeBufferPointer<Float>) {
      guard wantsActiveAtomic.load(ordering: .relaxed), !data.isEmpty else { return }
      unsafe processor.processBuffer(data)
    }

    public nonisolated func processBuffer(
      _ data: UnsafeBufferPointer<Float>,
      timing: BufferTiming,
    ) {
      guard wantsActiveAtomic.load(ordering: .relaxed), !data.isEmpty else { return }
      unsafe processor.processBuffer(data, timing: timing)
    }

    public nonisolated func endBufferTask() {
      wantsActiveAtomic.store(false, ordering: .relaxed)
      callbackTasks.run { [weak self] in
        await MainActor.run {
          self?.stopVisualization()
        }
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
        beatDetectionConfiguration: beatDetectionConfiguration,
      )
    }

    /// A configuration optimized for real-time recording visualization.
    public static let realTimeRecording = AudioVisualizationEngine.Configuration(
      amplitudeWindowSize: 256,
      spectrumSize: 128,
      analysisUpdateRateHz: 60.0,
      smoothingFactor: 0.4,
      bucketMode: .mel(bucketCount: 24),
      beatDetectionConfiguration: .default,
    )

    /// A low-power configuration for conserving battery.
    public static let lowPower = AudioVisualizationEngine.Configuration(
      amplitudeWindowSize: 128,
      spectrumSize: 64,
      analysisUpdateRateHz: 30.0,
      smoothingFactor: 0.5,
      bucketMode: .mel(bucketCount: 16),
      beatDetectionConfiguration: .lowSensitivity,
    )

    /// A high-quality configuration for detailed analysis.
    public static let highQuality = AudioVisualizationEngine.Configuration(
      amplitudeWindowSize: 1024,
      spectrumSize: 512,
      analysisUpdateRateHz: 60.0,
      smoothingFactor: 0.2,
      bucketMode: .mel(bucketCount: 32),
      beatDetectionConfiguration: .highSensitivity,
    )
  }

  extension AudioVisualizationEngine: VisualizationDriving {}

#endif
