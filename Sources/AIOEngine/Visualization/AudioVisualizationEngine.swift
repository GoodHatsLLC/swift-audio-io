#if canImport(AVFAudio)
import Tools
import AVFAudio
import Foundation
import SystemLog

private let log = SystemLog.make()

/// A high-performance audio visualization engine that processes audio data for real-time display.
///
/// This class provides both amplitude (waveform) and frequency (spectrum) analysis with minimal CPU overhead.
/// It can be used to create visualizations for live audio streams or pre-recorded audio files.
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
/// ### Accessing Visualization Data
///
/// - ``amplitudeData``
/// - ``spectrumData``
@Observable
public final class AudioVisualizationEngine: @unchecked Sendable, Identifiable {
  // MARK: - Public Properties

  public let id: UUID = .init()

  /// An array of floating-point values representing the audio waveform data.
  ///
  /// The values in this array are normalized to the range `[0.0, 1.0]`.
  public var amplitudeData: [Float] = []
  /// An array of floating-point values representing the audio spectrum data.
  ///
  /// The values in this array are normalized to the range `[0.0, 1.0]`.
  public var spectrumData: [Float] = []
  /// Frequencies corresponding to the current spectrum data.
  public var spectrumFrequencies: [Float] = []
  /// Peak-hold values for the spectrum with decay applied.
  public var spectrumPeakHold: [Float] = []
  /// Peak amplitudes with decay applied by the amplitude analyzer.
  public var peakAmplitudes: [Float] = []
  /// Rolling RMS level of the incoming audio stream.
  public var rmsLevel: Float = 0.0
  /// Overall amplitude level reported by the analyzer.
  public var overallLevel: Float = 0.0
  /// Brightness metric derived from the spectrum analyzer.
  public var spectralCentroid: Float = 0.0
  /// Frequency (Hz) of the strongest band in the latest spectrum frame.
  public var peakFrequency: Float = 0.0
  /// Cached frequency labels for UI overlays.
  public var frequencyLabels: [(frequency: Float, label: String)] = []
  /// A Boolean value that indicates whether the visualization engine is currently active.
  public var isActive = false

  // MARK: - Configuration

  /// A struct that defines the configuration for the audio visualization engine.
  public struct Configuration: Sendable {
    /// The number of samples to use for the amplitude waveform.
    let amplitudeWindowSize: Int
    /// The number of bins to use for the spectrum analysis.
    let spectrumSize: Int
    /// The number of times per second at which the visualization should be updated.
    let updateRateHz: Double
    /// A factor that controls the amount of smoothing applied to the visualization data.
    let smoothingFactor: Float
    /// The nominal sample rate of the source audio.
    let sampleRate: Double
    /// Configuration for the amplitude analyzer helper.
    let amplitudeAnalyzerConfiguration: AmplitudeAnalyzer.Configuration
    /// Optional configuration for the frequency analyzer helper.
    let frequencyAnalyzerConfiguration: FrequencyAnalyzer.Configuration?

    /// Creates a new configuration for the audio visualization engine.
    ///
    /// - Parameters:
    ///   - amplitudeWindowSize: The number of samples to use for the amplitude waveform. Defaults to 512.
    ///   - spectrumSize: The number of bins to use for the spectrum analysis. Defaults to 256.
    ///   - updateRateHz: The rate at which the visualization should be updated, in Hertz. Defaults to 60.0.
    ///   - smoothingFactor: A factor that controls the amount of smoothing applied to the visualization data. Defaults to 0.3.
    public init(
      amplitudeWindowSize: Int = 512,
      spectrumSize: Int = 256,
      updateRateHz: Double = 60.0,
      smoothingFactor: Float = 0.3,
      sampleRate: Double = 44_100.0,
      amplitudeAnalyzerConfiguration: AmplitudeAnalyzer.Configuration? = nil,
      frequencyAnalyzerConfiguration: FrequencyAnalyzer.Configuration? = nil
    ) {
      self.amplitudeWindowSize = amplitudeWindowSize
      self.spectrumSize = spectrumSize
      self.updateRateHz = updateRateHz
      self.smoothingFactor = smoothingFactor
      self.sampleRate = sampleRate

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

  // MARK: - Private Properties

  private let configuration: Configuration
  private let processingQueue = DispatchQueue(
    label: "audio-visualization",
    qos: .userInteractive
  )

  private let amplitudeAnalyzer: AmplitudeAnalyzer
  private let frequencyAnalyzer: FrequencyAnalyzer?
  private let frequencySampleCount: Int
  private let ringBuffer: RingBuffer<Float>
  private let maxVisualizationSamples: Int
  private var readScratchBuffer: [Float]

  // MARK: - Initialization

  /// Creates a new audio visualization engine with the specified configuration.
  ///
  /// - Parameter configuration: The configuration to use for the visualization engine.
  public init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
    self.amplitudeAnalyzer = AmplitudeAnalyzer(configuration: configuration.amplitudeAnalyzerConfiguration)

    var builtFrequencyAnalyzer: FrequencyAnalyzer?
    var frequencySampleCount = 0

    if let frequencyConfig = configuration.frequencyAnalyzerConfiguration {
      frequencySampleCount = frequencyConfig.fftSize
      do {
        builtFrequencyAnalyzer = try FrequencyAnalyzer(configuration: frequencyConfig)
      } catch {
        log.error("Failed to create FrequencyAnalyzer: \(error.localizedDescription, privacy: .public)")
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
    amplitudeData.removeAll()
    spectrumData.removeAll()
    spectrumFrequencies.removeAll()
    spectrumPeakHold.removeAll()
    peakAmplitudes.removeAll()
    rmsLevel = 0.0
    overallLevel = 0.0
    spectralCentroid = 0.0
    peakFrequency = 0.0
    ringBuffer.clearIndices()

    log.info("Audio visualization stopped")
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

    DispatchQueue.main.async {
      self.amplitudeData = amplitudeResult.amplitudes
      self.peakAmplitudes = amplitudeResult.peaks
      self.rmsLevel = amplitudeResult.rms
      self.overallLevel = amplitudeResult.overallLevel

      if let spectrumResult {
        self.spectrumData = spectrumResult.spectrum
        self.spectrumFrequencies = spectrumResult.frequencies
        self.peakFrequency = spectrumResult.peakFrequency
        self.spectralCentroid = spectrumResult.spectralCentroid
        self.updateSpectrumPeaks(with: spectrumResult.spectrum)
      } else {
        self.spectrumData = []
        self.spectrumFrequencies = []
        self.spectrumPeakHold = []
        self.peakFrequency = 0.0
        self.spectralCentroid = 0.0
      }
    }
  }

  private func updateSpectrumPeaks(with spectrum: [Float]) {
    let decayRate: Float = 0.015
    if spectrumPeakHold.count != spectrum.count {
      spectrumPeakHold = Array(repeating: 0.0, count: spectrum.count)
    }

    for index in spectrum.indices {
      let decayed = max(0.0, spectrumPeakHold[index] - decayRate)
      spectrumPeakHold[index] = max(decayed, spectrum[index])
    }
  }
}

extension AudioVisualizationEngine: BufferReceiver {
  public typealias T = Float

  nonisolated public func processBuffer(_ data: UnsafeBufferPointer<Float>) {
    guard isActive, data.count > 0 else { return }
    self.updateAudioBuffer(data)
  }
  public func endBufferTask() {

  }

}

// MARK: - Extensions for convenience

extension AudioVisualizationEngine.Configuration {
  /// A configuration optimized for real-time recording visualization.
  public static let realTimeRecording = AudioVisualizationEngine.Configuration(
    amplitudeWindowSize: 256,
    spectrumSize: 128,
    updateRateHz: 60.0,
    smoothingFactor: 0.4
  )

  /// A low-power configuration for conserving battery.
  public static let lowPower = AudioVisualizationEngine.Configuration(
    amplitudeWindowSize: 128,
    spectrumSize: 64,
    updateRateHz: 30.0,
    smoothingFactor: 0.5
  )

  /// A high-quality configuration for detailed analysis.
  public static let highQuality = AudioVisualizationEngine.Configuration(
    amplitudeWindowSize: 1024,
    spectrumSize: 512,
    updateRateHz: 60.0,
    smoothingFactor: 0.2
  )
}

#endif
