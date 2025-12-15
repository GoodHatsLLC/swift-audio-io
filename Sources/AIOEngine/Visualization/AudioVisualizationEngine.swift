#if canImport(AVFAudio)
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
        beatDetectionConfiguration: BeatDetectionConfiguration = .default
      ) {
        self.amplitudeWindowSize = amplitudeWindowSize
        self.spectrumSize = spectrumSize
        self.updateRateHz = updateRateHz
        self.smoothingFactor = smoothingFactor
        self.sampleRate = sampleRate
        self.bucketMode = bucketMode
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

    private let amplitudeAnalyzer: AmplitudeAnalyzer
    private let frequencyAnalyzer: FrequencyAnalyzer?
    private let frequencyBucketer: FrequencyBucketer
    private let beatDetector: BeatDetector
    private let frequencySampleCount: Int
    private let ringBuffer: RingBuffer<Float>
    private let maxVisualizationSamples: Int
    private var readScratchBuffer: [Float]
    private var lastUpdateTime: Date = .now

    // MARK: - Initialization

    /// Creates a new audio visualization engine with the specified configuration.
    ///
    /// - Parameter configuration: The configuration to use for the visualization engine.
    public init(configuration: Configuration = Configuration()) {
      self.configuration = configuration
      self.amplitudeAnalyzer = AmplitudeAnalyzer(
        configuration: configuration.amplitudeAnalyzerConfiguration)
      self.frequencyBucketer = FrequencyBucketer(
        mode: configuration.bucketMode,
        sampleRate: Float(configuration.sampleRate)
      )
      self.beatDetector = BeatDetector(configuration: configuration.beatDetectionConfiguration)

      var builtFrequencyAnalyzer: FrequencyAnalyzer?
      var frequencySampleCount = 0

      #if DEBUG
        let effectiveFrequencyConfig = configuration.frequencyAnalyzerConfiguration
      #else
        let effectiveFrequencyConfig: FrequencyAnalyzer.Configuration? = nil
      #endif

      if let frequencyConfig = effectiveFrequencyConfig {
        frequencySampleCount = frequencyConfig.fftSize
        do {
          builtFrequencyAnalyzer = try FrequencyAnalyzer(configuration: frequencyConfig)
        } catch {
          log.error(
            "Failed to create FrequencyAnalyzer: \(error.localizedDescription, privacy: .public)")
          frequencySampleCount = 0
        }
      }

      self.frequencyAnalyzer = builtFrequencyAnalyzer
      self.frequencySampleCount = frequencySampleCount

      if let analyzer = builtFrequencyAnalyzer {
        self.frequencyLabels = analyzer.getFrequencyLabels()
      }

      let maxSamples = max(configuration.amplitudeWindowSize, frequencySampleCount)
      let resolvedMaxSamples = max(maxSamples, 1)
      let ringCapacity = max(resolvedMaxSamples * 4, 1024)
      self.maxVisualizationSamples = resolvedMaxSamples
      self.ringBuffer = RingBuffer<Float>(capacity: ringCapacity)
      self.readScratchBuffer = Array(repeating: 0.0, count: resolvedMaxSamples)
    }

    deinit {
      stopVisualization()
    }

    // MARK: - Public Interface

    /// Starts the visualization processing.
    public func startVisualization() {
      guard !isActive else { return }

      isActive = true
      lastUpdateTime = .now
      setupUpdateTimer()
      log.info("Audio visualization started")
    }

    /// Stops the visualization processing.
    public func stopVisualization() {
      guard isActive else { return }

      updateTimer?.cancel()
      updateTimer = nil
      isActive = false

      // Clear data
      timeDomain = .empty
      frequencyDomain = .empty
      beat = .empty
      spectrumPeakHold.removeAll()
      frequencyBucketer.resetPeakHold()
      beatDetector.reset()
      ringBuffer.clearIndices()
      lodProcessor?.reset()

      log.info("Audio visualization stopped")
    }

    /// Updates the frequency bucket mode.
    ///
    /// - Parameter mode: The new bucketing mode to use.
    public func updateBucketMode(_ mode: FrequencyBucketMode) {
      frequencyBucketer.updateMode(mode)
    }

    /// Updates the beat detection configuration.
    ///
    /// - Parameter configuration: The new beat detection configuration.
    public func updateBeatDetectionConfiguration(_ configuration: BeatDetectionConfiguration) {
      beatDetector.updateConfiguration(configuration)
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
        snapshotSwapInterval: configuration.snapshotSwapInterval
      )
      lodProcessor = MultiBandLODProcessor(configuration: resolvedConfig)
      log.info("Multi-band LOD enabled: \(configuration.bandCount, privacy: .public) bands")
    }

    /// Disables multi-band LOD processing.
    public func disableMultiBandLOD() {
      lodProcessor = nil
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
      guard isActive,
        let floatData = buffer.floatChannelData?[0]
      else { return }

      let bufferPointer = UnsafeBufferPointer(
        start: floatData,
        count: Int(buffer.frameLength)
      )
      processBuffer(bufferPointer)
    }

    // MARK: - Private Methods

    private var updateTimer: DispatchSourceTimer?

    private func setupUpdateTimer() {
      let interval = 1.0 / configuration.updateRateHz
      let timer = DispatchSource.makeTimerSource(queue: processingQueue)
      timer.schedule(deadline: .now(), repeating: interval)
      timer.setEventHandler { [weak self] in
        self?.updateVisualizations()
      }
      timer.resume()
      self.updateTimer = timer
    }

    private func updateAudioBuffer(_ data: UnsafeBufferPointer<Float>) {
      guard !data.isEmpty else { return }
      ringBuffer.write(data)
    }

    private func updateVisualizations() {
      let now = Date.now
      let deltaTime = now.timeIntervalSince(lastUpdateTime)
      lastUpdateTime = now

      let desiredSamples = maxVisualizationSamples
      var readCount = 0

      readScratchBuffer.withUnsafeMutableBufferPointer { bufferPointer in
        guard let base = bufferPointer.baseAddress else { return }
        let limitedBuffer = UnsafeMutableBufferPointer(start: base, count: desiredSamples)
        readCount = ringBuffer.read(into: limitedBuffer)
      }

      guard readCount > 0 else { return }

      let audioChunk = Array(readScratchBuffer.prefix(readCount))
      let amplitudeResult = amplitudeAnalyzer.processAmplitudeData(audioChunk)
      let spectrumResult = frequencyAnalyzer?.processFrequencyData(audioChunk)

      // Build time-domain data
      let newTimeDomain = TimeDomainData(
        samples: amplitudeResult.amplitudes,
        peaks: amplitudeResult.peaks,
        rmsLevel: amplitudeResult.rms,
        level: amplitudeResult.overallLevel
      )

      // Build frequency-domain data
      var newFrequencyDomain = FrequencyDomainData.empty
      var newSpectrumPeakHold: [Float] = []

      if let spectrumResult {
        let buckets = frequencyBucketer.bucket(
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

        // Update spectrum peak hold for legacy API
        newSpectrumPeakHold = updateSpectrumPeaks(
          current: spectrumPeakHold,
          newSpectrum: spectrumResult.spectrum
        )
      }

      // Beat detection
      let beatInfo = beatDetector.analyze(
        spectrum: spectrumResult?.spectrum ?? [],
        rmsLevel: amplitudeResult.rms,
        deltaTime: deltaTime
      )

      DispatchQueue.main.async {
        self.timeDomain = newTimeDomain
        self.frequencyDomain = newFrequencyDomain
        self.spectrumPeakHold = newSpectrumPeakHold
        self.beat = beatInfo
      }
    }

    private func updateSpectrumPeaks(current: [Float], newSpectrum: [Float]) -> [Float] {
      let decayRate: Float = 0.015

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
      guard isActive, data.count > 0 else { return }
      self.updateAudioBuffer(data)

      // Also feed multi-band LOD processor if enabled
      lodProcessor?.process(data)
    }

    public func endBufferTask() {}
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
