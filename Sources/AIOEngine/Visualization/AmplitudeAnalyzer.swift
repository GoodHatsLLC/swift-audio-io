#if canImport(Accelerate)
  import Accelerate
  import Foundation
  import SystemLog

  private let sysLog = SystemLog.make()

  /// High-performance amplitude analyzer optimized for real-time audio visualization
  /// Provides efficient amplitude tracking, peak detection, and smoothing algorithms
  public final class AmplitudeAnalyzer {
    // MARK: - Configuration

    public struct Configuration: Sendable, Equatable {
      public let windowSize: Int
      public let smoothingFactor: Float
      public let peakDecayRate: Float
      public let noiseFloor: Float

      public init(
        windowSize: Int,
        smoothingFactor: Float,
        peakDecayRate: Float,
        noiseFloor: Float
      ) {
        self.windowSize = windowSize
        self.smoothingFactor = smoothingFactor
        self.peakDecayRate = peakDecayRate
        self.noiseFloor = noiseFloor
      }
    }

    // MARK: - Properties

    private let configuration: Configuration
    private var smoothedAmplitudes: [Float]
    private var peakAmplitudes: [Float]
    private var rmsHistory: [Float] = []
    private let maxRMSHistory = 10

    // vDSP optimization buffers
    private var workBuffer: [Float]
    private var tempBuffer: [Float]
    private var decimatedData: [Float]

    // MARK: - Initialization

    public init(configuration: Configuration) {
      self.configuration = configuration
      let windowSize = configuration.windowSize
      smoothedAmplitudes = Array(repeating: 0.0, count: windowSize)
      peakAmplitudes = Array(repeating: 0.0, count: windowSize)
      workBuffer = Array(repeating: 0.0, count: windowSize)
      tempBuffer = Array(repeating: 0.0, count: windowSize)
      decimatedData = Array(repeating: 0.0, count: windowSize)
    }

    // MARK: - Public Interface

    /// Process raw audio data and return amplitude visualization data
    /// - Parameter audioData: Raw audio samples
    /// - Returns: Processed amplitude data for visualization
    public func processAmplitudeData(_ audioData: [Float]) -> AmplitudeData {
      guard !audioData.isEmpty else {
        // When there's no audio, decay the peaks
        let peaks = calculatePeaks([])
        return AmplitudeData(
          amplitudes: smoothedAmplitudes,
          peaks: peaks,
          rms: 0.0,
          overallLevel: 0.0
        )
      }

      let decimated = decimateAudioData(audioData)
      let amplitudes = calculateAmplitudes(decimated)
      let peaks = calculatePeaks(amplitudes)
      let rms = calculateRMS(audioData)
      let overallLevel = calculateOverallLevel(amplitudes)

      return AmplitudeData(
        amplitudes: amplitudes,
        peaks: peaks,
        rms: rms,
        overallLevel: overallLevel
      )
    }

    // MARK: - Private Methods

    /// Efficiently decimates audio data to match the visualization window size using vDSP.
    private func decimateAudioData(_ data: [Float]) -> [Float] {
      let inputSize = data.count
      let outputSize = configuration.windowSize

      if inputSize == outputSize {
        return data
      } else if inputSize < outputSize {
        return data + [Float](repeating: 0.0, count: outputSize - inputSize)
      }

      let stride = Float(inputSize) / Float(outputSize)

      data.withUnsafeBufferPointer { dataPtr in
        if let source = dataPtr.baseAddress {
          decimatedData.withUnsafeMutableBufferPointer { decimatedPtr in
            if let destination = decimatedPtr.baseAddress {
              for i in 0..<outputSize {
                let startIndex = Int(Float(i) * stride)
                let endIndex = Int(Float(i + 1) * stride)
                let effectiveEndIndex = min(endIndex, inputSize)
                let N = vDSP_Length(effectiveEndIndex - startIndex)

                if N > 0 {
                  vDSP_meamgv(source.advanced(by: startIndex), 1, destination.advanced(by: i), N)
                } else {
                  destination[i] = 0.0
                }
              }
            }
          }
        }
      }
      return decimatedData
    }

    /// Calculates smoothed amplitude values using exponential smoothing with vDSP.
    private func calculateAmplitudes(_ data: [Float]) -> [Float] {
      let count = vDSP_Length(configuration.windowSize)
      var smoothingFactor = configuration.smoothingFactor
      var invSmoothingFactor = 1.0 - smoothingFactor
      var noiseFloor = configuration.noiseFloor

      // tempBuffer = max(data, noiseFloor)
      vDSP_vthres(data, 1, &noiseFloor, &tempBuffer, 1, count)

      // workBuffer = tempBuffer * smoothingFactor
      vDSP_vsmul(&tempBuffer, 1, &smoothingFactor, &workBuffer, 1, count)

      // tempBuffer = smoothedAmplitudes * invSmoothingFactor
      vDSP_vsmul(&smoothedAmplitudes, 1, &invSmoothingFactor, &tempBuffer, 1, count)

      // smoothedAmplitudes = tempBuffer + workBuffer
      vDSP_vadd(&tempBuffer, 1, &workBuffer, 1, &smoothedAmplitudes, 1, count)

      return smoothedAmplitudes
    }

    /// Calculates peak values with decay for visualization using vDSP.
    private func calculatePeaks(_ amplitudes: [Float]) -> [Float] {
      let count = vDSP_Length(configuration.windowSize)
      var decayRate = configuration.peakDecayRate

      // tempBuffer = peakAmplitudes * decayRate
      vDSP_vsmul(&peakAmplitudes, 1, &decayRate, &tempBuffer, 1, count)

      if amplitudes.isEmpty {
        // If no new amplitudes, the decayed peaks are the new peaks
        peakAmplitudes = tempBuffer
      } else {
        // peakAmplitudes = max(amplitudes, tempBuffer)
        vDSP_vmax(amplitudes, 1, &tempBuffer, 1, &peakAmplitudes, 1, count)
      }

      return peakAmplitudes
    }

    /// Calculate RMS (Root Mean Square) value using vDSP for performance
    private func calculateRMS(_ data: [Float]) -> Float {
      guard !data.isEmpty else { return 0.0 }

      let count = data.count
      var result: Float = 0.0
      vDSP_rmsqv(data, 1, &result, vDSP_Length(count))

      // Add to history for trend analysis
      rmsHistory.append(result)
      if rmsHistory.count > maxRMSHistory {
        rmsHistory.removeFirst()
      }

      return result
    }

    /// Calculate overall audio level for meters
    private func calculateOverallLevel(_ amplitudes: [Float]) -> Float {
      guard !amplitudes.isEmpty else { return 0.0 }

      var maxValue: Float = 0.0
      vDSP_maxv(amplitudes, 1, &maxValue, vDSP_Length(amplitudes.count))

      return maxValue
    }

    // MARK: - Utility Methods

    /// Get RMS trend for advanced visualizations
    public func getRMSTrend() -> [Float] {
      return rmsHistory
    }

    /// Reset all internal state
    public func reset() {
      vDSP_vclr(&smoothedAmplitudes, 1, vDSP_Length(configuration.windowSize))
      vDSP_vclr(&peakAmplitudes, 1, vDSP_Length(configuration.windowSize))
      rmsHistory.removeAll()
    }
  }
#endif

// MARK: - Data Structures

/// Container for processed amplitude visualization data
public struct AmplitudeData {
  /// Smoothed amplitude values for waveform display
  public let amplitudes: [Float]

  /// Peak values with decay for peak meters
  public let peaks: [Float]

  /// RMS (Root Mean Square) value for overall level
  public let rms: Float

  /// Overall audio level (0.0 to 1.0)
  public let overallLevel: Float
}

// MARK: - Configuration Extensions

extension AmplitudeAnalyzer.Configuration {
  /// Optimized for real-time recording with minimal CPU impact
  public static let realTime = AmplitudeAnalyzer.Configuration(
    windowSize: 128,
    smoothingFactor: 0.4,
    peakDecayRate: 0.92,
    noiseFloor: 0.001
  )

  /// High-quality analysis for detailed visualization
  public static let highQuality = AmplitudeAnalyzer.Configuration(
    windowSize: 512,
    smoothingFactor: 0.2,
    peakDecayRate: 0.98,
    noiseFloor: 0.0005
  )

  /// Low-power mode for battery conservation
  public static let lowPower = AmplitudeAnalyzer.Configuration(
    windowSize: 64,
    smoothingFactor: 0.6,
    peakDecayRate: 0.90,
    noiseFloor: 0.002
  )
}
