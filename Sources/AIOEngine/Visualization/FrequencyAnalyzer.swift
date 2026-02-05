#if canImport(Accelerate)
  import Accelerate
  import Foundation
  import SystemLog
  import Tools

  private let sysLog = SystemLog.make()

  /// High-performance frequency analyzer using vDSP for real-time FFT-based spectrum analysis
  /// Optimized to minimize CPU overhead while providing detailed frequency visualization data
  @safe public final class FrequencyAnalyzer {
    // MARK: - Configuration

    public struct Configuration: Sendable, Equatable {
      public let fftSize: Int
      public let spectrumSize: Int
      public let sampleRate: Double
      public let smoothingFactor: Float
      public let noiseFloor: Float
      public let windowType: WindowType

      public init(
        fftSize: Int,
        spectrumSize: Int,
        sampleRate: Double,
        smoothingFactor: Float,
        noiseFloor: Float,
        windowType: WindowType
      ) {
        self.fftSize = fftSize
        self.spectrumSize = min(spectrumSize, fftSize / 2)
        self.sampleRate = sampleRate
        self.smoothingFactor = smoothingFactor
        self.noiseFloor = noiseFloor
        self.windowType = windowType
      }
    }

    public enum WindowType: Sendable {
      case hann
      case hamming
      case blackman
      case blackmanHarris
      case rectangular
    }

    // MARK: - Properties

    private let configuration: Configuration
    private let log2n: vDSP_Length

    // vDSP FFT setup
    private var fftSetup: vDSP.FFT<DSPSplitComplex>
    private var complexBuffer: DSPSplitComplex
    private var window: [Float]

    // Processing buffers
    private var magnitudes: [Float]
    private var smoothedSpectrum: [Float]
    private var inputBuffer: [Float]
    private var windowedBuffer: [Float]
    private var tempSpectrum: [Float]
    private var workBuffer: [Float]

    // Frequency mapping
    private var frequencyBins: [Float]

    // MARK: - Initialization

    public init(configuration: Configuration) throws(FrequencyAnalyzerError) {
      self.configuration = configuration

      // Validate FFT size (must be power of 2)
      guard configuration.fftSize > 0 && (configuration.fftSize & (configuration.fftSize - 1)) == 0
      else {
        throw FrequencyAnalyzerError.invalidFFTSize
      }

      log2n = vDSP_Length(log2(Double(configuration.fftSize)))

      // Initialize FFT
      guard
        let setup = unsafe vDSP.FFT(
          log2n: log2n,
          radix: .radix2,
          ofType: DSPSplitComplex.self)
      else {
        throw FrequencyAnalyzerError.allocationFailed
      }
      unsafe fftSetup = unsafe setup

      // Allocate buffers
      let halfSize = configuration.fftSize / 2
      let realPtr = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
      let imagPtr = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
      unsafe complexBuffer = unsafe DSPSplitComplex(realp: realPtr, imagp: imagPtr)

      magnitudes = Array(repeating: 0.0, count: halfSize)
      smoothedSpectrum = Array(repeating: 0.0, count: configuration.spectrumSize)
      tempSpectrum = Array(repeating: 0.0, count: configuration.spectrumSize)
      workBuffer = Array(repeating: 0.0, count: configuration.spectrumSize)
      inputBuffer = Array(repeating: 0.0, count: configuration.fftSize)
      windowedBuffer = Array(repeating: 0.0, count: configuration.fftSize)

      // Create window function
      window = Self.createWindow(
        type: configuration.windowType,
        size: configuration.fftSize
      )

      // Calculate frequency bins
      frequencyBins = Self.calculateFrequencyBins(
        fftSize: configuration.fftSize,
        sampleRate: configuration.sampleRate,
        spectrumSize: configuration.spectrumSize
      )
    }

    deinit {
      unsafe complexBuffer.realp.deallocate()
      unsafe complexBuffer.imagp.deallocate()
    }

    // MARK: - Public Interface

    /// Process audio data and return frequency spectrum
    /// - Parameter audioData: Raw audio samples
    /// - Returns: Processed frequency spectrum data
    public func processFrequencyData(_ audioData: [Float]) -> SpectrumData {
      guard !audioData.isEmpty else {
        // On empty audio, decay the spectrum towards zero
        let decayedSpectrum = calculateSpectrum(isSilent: true)
        return SpectrumData(
          spectrum: decayedSpectrum,
          frequencies: frequencyBins,
          peakFrequency: 0.0,
          spectralCentroid: 0.0
        )
      }

      prepareInputBuffer(audioData)
      applyWindow()
      performFFT()
      let spectrum = calculateSpectrum()
      let peakFreq = findPeakFrequency(spectrum)
      let centroid = calculateSpectralCentroid(spectrum)

      return SpectrumData(
        spectrum: spectrum,
        frequencies: frequencyBins,
        peakFrequency: peakFreq,
        spectralCentroid: centroid
      )
    }

    /// Get frequency labels for visualization axes
    public func getFrequencyLabels(count: Int = 5) -> [(frequency: Float, label: String)] {
      let step = configuration.spectrumSize / max(1, count - 1)
      var labels: [(Float, String)] = []

      for i in 0..<count {
        let index = min(i * step, frequencyBins.count - 1)
        let freq = frequencyBins[index]
        let label = formatFrequency(freq)
        labels.append((freq, label))
      }

      return labels
    }

    // MARK: - Private Methods

    /// Prepare input buffer with latest audio data using a sliding window.
    private func prepareInputBuffer(_ audioData: [Float]) {
      let dataCount = audioData.count
      let fftSize = configuration.fftSize

      unsafe inputBuffer.withUnsafeMutableBufferPointer { destinationPtr in
        guard let destinationBase = destinationPtr.baseAddress else { return }

        if dataCount >= fftSize {
          // If new data is larger than or equal to buffer, just take the latest samples
          unsafe audioData.withUnsafeBufferPointer { sourcePtr in
            guard let sourceBase = sourcePtr.baseAddress else { return }
            let start = unsafe sourceBase.advanced(by: dataCount - fftSize)
            unsafe memcpy(destinationBase, start, fftSize * MemoryLayout<Float>.size)
          }
        } else {
          // Shift existing data to the left and append new data
          let shiftCount = fftSize - dataCount
          let bytesToMove = shiftCount * MemoryLayout<Float>.size
          unsafe memmove(destinationBase, destinationBase.advanced(by: dataCount), bytesToMove)

          unsafe audioData.withUnsafeBufferPointer { sourcePtr in
            guard let sourceBase = sourcePtr.baseAddress else { return }
            unsafe memcpy(
              destinationBase.advanced(by: shiftCount),
              sourceBase,
              dataCount * MemoryLayout<Float>.size)
          }
        }
      }
    }

    /// Apply window function to reduce spectral leakage
    private func applyWindow() {
      vDSP.multiply(inputBuffer, window, result: &windowedBuffer)
    }

    /// Perform FFT using vDSP
    private func performFFT() {
      let halfSize = configuration.fftSize / 2
      // Pack real windowed buffer into complex format for FFT
      unsafe windowedBuffer.withUnsafeBufferPointer { bufferPtr in
        guard let baseAddress = bufferPtr.baseAddress else { return }
        for index in 0..<halfSize {
          let evenSample = unsafe baseAddress.advanced(by: index * 2)
          let oddSample = unsafe evenSample.advanced(by: 1)
          unsafe complexBuffer.realp[index] = unsafe evenSample.pointee
          unsafe complexBuffer.imagp[index] = unsafe oddSample.pointee
        }
      }

      // Perform forward FFT in-place
      unsafe fftSetup.forward(input: complexBuffer, output: &complexBuffer)

      // Calculate magnitudes from the complex FFT output
      let magCount = magnitudes.count
      unsafe magnitudes.withUnsafeMutableBufferPointer { magnitudesPtr in
        guard let magnitudesBase = magnitudesPtr.baseAddress else { return }
        unsafe vDSP_zvabs(&complexBuffer, 1, magnitudesBase, 1, vDSP_Length(magCount))

        // Normalize magnitudes
        var scale: Float = 2.0 / Float(configuration.fftSize)
        unsafe vDSP_vsmul(
          magnitudesBase,
          1,
          &scale,
          magnitudesBase,
          1,
          vDSP_Length(magCount))
      }
    }

    /// Convert magnitudes to spectrum with smoothing and normalization
    private func calculateSpectrum(isSilent: Bool = false) -> [Float] {
      let spectrumSize = vDSP_Length(configuration.spectrumSize)
      let halfFftSize = configuration.fftSize / 2

      if isSilent {
        // Decay spectrum towards zero when no audio is present
        unsafe smoothedSpectrum.withUnsafeMutableBufferPointer { smoothedPtr in
          guard let smoothedBase = smoothedPtr.baseAddress else { return }
          var decayFactor = 1.0 - configuration.smoothingFactor
          unsafe vDSP_vsmul(smoothedBase, 1, &decayFactor, smoothedBase, 1, spectrumSize)
        }
        return smoothedSpectrum
      }

      // Resample magnitudes to spectrum size
      let binStep = Float(halfFftSize) / Float(spectrumSize)
      for i in 0..<Int(spectrumSize) {
        let binIndex = min(Int(Float(i) * binStep), halfFftSize - 1)
        tempSpectrum[i] = magnitudes[binIndex]
      }

      // Convert to dB, with a floor to prevent -inf
      unsafe tempSpectrum.withUnsafeMutableBufferPointer { tempPtr in
        guard let tempBase = tempPtr.baseAddress else { return }

        // Convert to dB, with a floor to prevent -inf
        var zeroDB = powf(10.0, configuration.noiseFloor / 10.0)
        unsafe vDSP_vthr(tempBase, 1, &zeroDB, tempBase, 1, spectrumSize)
        var one: Float = 1.0
        unsafe vDSP_vdbcon(tempBase, 1, &one, tempBase, 1, spectrumSize, 1)

        // Normalize to 0-1 range: (dB - floor) / -floor = (dB / -floor) + 1
        var invNoiseFloor: Float = -1.0 / configuration.noiseFloor
        unsafe vDSP_vsmul(tempBase, 1, &invNoiseFloor, tempBase, 1, spectrumSize)
        unsafe vDSP_vsadd(tempBase, 1, &one, tempBase, 1, spectrumSize)

        // Clip to 0-1
        var low: Float = 0.0
        var high: Float = 1.0
        unsafe vDSP_vclip(tempBase, 1, &low, &high, tempBase, 1, spectrumSize)

        // Apply exponential smoothing
        unsafe smoothedSpectrum.withUnsafeMutableBufferPointer { smoothedPtr in
          guard let smoothedBase = smoothedPtr.baseAddress else { return }
          unsafe workBuffer.withUnsafeMutableBufferPointer { workPtr in
            guard let workBase = workPtr.baseAddress else { return }
            var smoothingFactor = configuration.smoothingFactor
            var invSmoothingFactor: Float = 1.0 - smoothingFactor
            unsafe vDSP_vsmul(smoothedBase, 1, &invSmoothingFactor, workBase, 1, spectrumSize)
            unsafe vDSP_vsmul(tempBase, 1, &smoothingFactor, tempBase, 1, spectrumSize)
            unsafe vDSP_vadd(workBase, 1, tempBase, 1, smoothedBase, 1, spectrumSize)
          }
        }
      }

      return smoothedSpectrum
    }

    /// Find peak frequency in the spectrum
    private func findPeakFrequency(_ spectrum: [Float]) -> Float {
      guard !spectrum.isEmpty else { return 0.0 }

      var maxIndex: vDSP_Length = 0
      var maxValue: Float = 0.0
      unsafe vDSP_maxvi(spectrum, 1, &maxValue, &maxIndex, vDSP_Length(spectrum.count))

      let binIndex = min(Int(maxIndex), frequencyBins.count - 1)
      return frequencyBins[binIndex]
    }

    /// Calculate spectral centroid (brightness measure)
    private func calculateSpectralCentroid(_ spectrum: [Float]) -> Float {
      guard !spectrum.isEmpty else { return 0.0 }

      var weightedSum: Float = 0.0
      var magnitudeSum: Float = 0.0

      let count = vDSP_Length(min(spectrum.count, frequencyBins.count))

      // weightedSum = sum(spectrum * frequencies)
      unsafe vDSP_dotpr(spectrum, 1, frequencyBins, 1, &weightedSum, count)

      // magnitudeSum = sum(spectrum)
      unsafe vDSP_sve(spectrum, 1, &magnitudeSum, count)

      return magnitudeSum > 0 ? weightedSum / magnitudeSum : 0.0
    }

    /// Format frequency for display labels
    private func formatFrequency(_ frequency: Float) -> String {
      if frequency >= 1000 {
        return unsafe String(format: "%.1fk", frequency / 1000)
      } else {
        return unsafe String(format: "%.0f", frequency)
      }
    }

    // MARK: - Static Factory Methods

    /// Create window function
    private static func createWindow(type: WindowType, size: Int) -> [Float] {
      var window = [Float](repeating: 0, count: size)
      unsafe window.withUnsafeMutableBufferPointer { ptr in
        guard let windowPtr = ptr.baseAddress else { return }

        switch type {
        case .hann:
          unsafe vDSP_hann_window(windowPtr, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        case .hamming:
          unsafe vDSP_hamm_window(windowPtr, vDSP_Length(size), 0)
        case .blackman, .blackmanHarris:
          unsafe vDSP_blkman_window(windowPtr, vDSP_Length(size), 0)
        case .rectangular:
          var one: Float = 1.0
          unsafe vDSP_vfill(&one, windowPtr, 1, vDSP_Length(size))
        }
      }
      return window
    }

    /// Calculate frequency bins for spectrum mapping
    private static func calculateFrequencyBins(
      fftSize: Int,
      sampleRate: Double,
      spectrumSize: Int
    ) -> [Float] {
      guard spectrumSize > 0 else { return [] }

      // When the spectrum is downsampled (spectrumSize < halfFft), each spectrum
      // index corresponds to an FFT bin at `index * binStep`. The frequency for
      // each spectrum bin must account for this stride:
      //   frequency = binIndex * sampleRate / fftSize
      //             = (index * binStep) * sampleRate / fftSize
      //             = index * (halfFft / spectrumSize) * sampleRate / fftSize
      //             = index * sampleRate / (2 * spectrumSize)
      //             = index * nyquist / spectrumSize
      let nyquist = Float(sampleRate) / 2.0
      let increment = nyquist / Float(spectrumSize)

      return (0..<spectrumSize).map {
        Float($0) * increment
      }
    }

    // MARK: - Utility Methods

    /// Reset all internal state
    public func reset() {
      unsafe smoothedSpectrum.withUnsafeMutableBufferPointer { ptr in
        guard let base = ptr.baseAddress else { return }
        unsafe vDSP_vclr(base, 1, vDSP_Length(configuration.spectrumSize))
      }
      unsafe magnitudes.withUnsafeMutableBufferPointer { ptr in
        guard let base = ptr.baseAddress else { return }
        unsafe vDSP_vclr(base, 1, vDSP_Length(configuration.fftSize / 2))
      }
      unsafe inputBuffer.withUnsafeMutableBufferPointer { ptr in
        guard let base = ptr.baseAddress else { return }
        unsafe vDSP_vclr(base, 1, vDSP_Length(configuration.fftSize))
      }
    }
  }
#endif

// MARK: - Data Structures

/// Container for processed frequency spectrum data
public struct SpectrumData {
  /// Frequency spectrum values (0.0 to 1.0)
  public let spectrum: [Float]

  /// Frequency values corresponding to spectrum bins
  public let frequencies: [Float]

  /// Peak frequency in Hz
  public let peakFrequency: Float

  /// Spectral centroid (brightness measure) in Hz
  public let spectralCentroid: Float
}

// MARK: - Errors

public enum FrequencyAnalyzerError: AudioError, LocalizedError {
  case invalidFFTSize
  case allocationFailed

  public var errorDescription: String? {
    switch self {
    case .invalidFFTSize:
      return "FFT size must be a power of 2"
    case .allocationFailed:
      return "Failed to allocate memory for FFT buffers"
    }
  }

  public var description: String {
    errorDescription ?? String(describing: self)
  }
}

// MARK: - Configuration Extensions

extension FrequencyAnalyzer.Configuration {
  /// Optimized for real-time recording with minimal CPU impact
  public static let realTime = FrequencyAnalyzer.Configuration(
    fftSize: 512,
    spectrumSize: 128,
    sampleRate: 44100.0,
    smoothingFactor: 0.4,
    noiseFloor: -60.0,
    windowType: .hann
  )

  /// High-quality analysis for detailed spectrum visualization
  public static let highQuality = FrequencyAnalyzer.Configuration(
    fftSize: 2048,
    spectrumSize: 512,
    sampleRate: 44100.0,
    smoothingFactor: 0.2,
    noiseFloor: -80.0,
    windowType: .blackman
  )

  /// Low-power mode for battery conservation
  public static let lowPower = FrequencyAnalyzer.Configuration(
    fftSize: 256,
    spectrumSize: 64,
    sampleRate: 44100.0,
    smoothingFactor: 0.6,
    noiseFloor: -50.0,
    windowType: .hann
  )
}
