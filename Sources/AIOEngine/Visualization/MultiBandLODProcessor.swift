#if canImport(AVFAudio)
  import Foundation
  import AVFAudio
  import os

  private let log = OSLog(subsystem: "AIOEngine", category: "MultiBandLOD")

  /// Processes audio samples into multi-band Level-of-Detail data for GPU visualization.
  ///
  /// This processor implements:
  /// 1. Cascading lowpass filter bank to split audio into frequency bands
  /// 2. LOD reduction (e.g., 128:1) computing min/max/RMS per window
  /// 3. Circular buffer storage for streaming visualization
  ///
  /// Thread-safe for concurrent audio processing.
  public final class MultiBandLODProcessor: @unchecked Sendable {

    // MARK: - Configuration

    private let configuration: MultiBandLODConfiguration
    private let crossoverAlphas: [Float]

    // MARK: - State (Protected by lock)

    private let lock = NSLock()

    /// Filter states for cascading lowpass (one per band)
    private var filterStates: [Float]

    /// Accumulators for LOD computation (samples within current window)
    private var accumulators: [[Float]]

    /// LOD buffers for each band
    private var lodBands: [BandLODData]

    /// Current write index in LOD circular buffer
    private var lodWriteIndex: Int = 0

    /// Total samples processed (for debugging)
    private var totalSamplesProcessed: Int = 0

    // MARK: - Initialization

    /// Creates a new multi-band LOD processor.
    ///
    /// - Parameter configuration: Processing configuration.
    public init(configuration: MultiBandLODConfiguration = .default) {
      self.configuration = configuration

      // Compute crossover filter alphas
      self.crossoverAlphas = configuration.crossoverMode.computeAlphas(
        bandCount: configuration.bandCount,
        sampleRate: configuration.sampleRate
      )

      // Initialize filter states
      self.filterStates = Array(repeating: 0, count: configuration.bandCount)

      // Initialize accumulators
      self.accumulators = Array(
        repeating: [],
        count: configuration.bandCount
      )
      for i in 0..<configuration.bandCount {
        accumulators[i].reserveCapacity(configuration.lodRatio * 2)
      }

      // Initialize LOD buffers
      self.lodBands = (0..<configuration.bandCount).map { bandIndex in
        BandLODData(bandIndex: bandIndex, capacity: configuration.lodBufferLength)
      }

      os_log(
        .info, log: log, "Initialized with %d bands, LOD ratio %d, buffer %d seconds",
        configuration.bandCount, configuration.lodRatio, configuration.bufferSeconds)
    }

    // MARK: - Processing

    /// Process raw audio samples through the multi-band filter bank.
    ///
    /// Samples are filtered into frequency bands, accumulated, and when
    /// enough samples are collected, LOD values (min/max/RMS) are computed
    /// and written to circular buffers.
    ///
    /// - Parameter samples: Raw audio samples (mono, normalized to [-1, 1]).
    public func process(_ samples: UnsafeBufferPointer<Float>) {
      guard !samples.isEmpty else { return }

      lock.lock()
      defer { lock.unlock() }

      let bandCount = configuration.bandCount
      let lodRatio = configuration.lodRatio

      for i in 0..<samples.count {
        let x = samples[i]

        // Cascading lowpass filter bank
        // Each band gets: (lowpass at cutoff) - (lowpass at previous cutoff)
        // Final band gets: input - (lowpass at highest cutoff)
        var lowerBoundSignal: Float = 0

        for b in 0..<bandCount {
          let part: Float
          if b == bandCount - 1 {
            // Highest band: everything above the last crossover
            part = x - lowerBoundSignal
          } else {
            // Apply lowpass filter
            let alpha = crossoverAlphas[b]
            let prev = filterStates[b]
            let lp = prev + alpha * (x - prev)
            filterStates[b] = lp

            // This band's contribution
            part = lp - lowerBoundSignal
            lowerBoundSignal = lp
          }

          accumulators[b].append(part)
        }

        // Check if we have enough samples for an LOD commit
        if accumulators[0].count >= lodRatio {
          commitLOD()
        }
      }

      totalSamplesProcessed += samples.count
    }

    /// Process samples from a contiguous array.
    ///
    /// - Parameter samples: Raw audio samples.
    public func process(_ samples: [Float]) {
      samples.withUnsafeBufferPointer { buffer in
        process(buffer)
      }
    }

    /// Process samples from an AVAudioPCMBuffer (first channel only).
    ///
    /// - Parameter buffer: Audio buffer to process.
    @available(iOS 13.0, macOS 10.15, *)
    public func process(_ buffer: AVFAudio.AVAudioPCMBuffer) {
      guard let floatData = buffer.floatChannelData?[0] else { return }
      let bufferPointer = UnsafeBufferPointer(
        start: floatData,
        count: Int(buffer.frameLength)
      )
      process(bufferPointer)
    }

    // MARK: - LOD Commit

    private func commitLOD() {
      // Already holding lock from process()
      let bandCount = configuration.bandCount
      let wIdx = lodWriteIndex

      for b in 0..<bandCount {
        let samples = accumulators[b]
        guard !samples.isEmpty else { continue }

        var minV: Float = 1.0
        var maxV: Float = -1.0
        var sumSq: Float = 0
        let count = Float(samples.count)

        for val in samples {
          if val < minV { minV = val }
          if val > maxV { maxV = val }
          sumSq += (val * val)
        }

        lodBands[b].minBuffer[wIdx] = minV
        lodBands[b].maxBuffer[wIdx] = maxV
        lodBands[b].rmsBuffer[wIdx] = sqrt(sumSq / count)

        accumulators[b].removeAll(keepingCapacity: true)
      }

      lodWriteIndex = (lodWriteIndex + 1) % configuration.lodBufferLength
    }

    // MARK: - Snapshot

    /// Creates a snapshot of current LOD data for rendering.
    ///
    /// This is thread-safe and returns an immutable copy of the data.
    ///
    /// - Returns: Complete LOD snapshot ready for GPU rendering.
    public func snapshot() -> MultiBandLODSnapshot {
      lock.lock()
      defer { lock.unlock() }

      return MultiBandLODSnapshot(
        bands: lodBands,
        writeIndex: lodWriteIndex,
        lodRatio: configuration.lodRatio,
        rawBufferLength: configuration.rawBufferLength
      )
    }

    // MARK: - Reset

    /// Resets all buffers and filter states.
    ///
    /// Call this when starting a new recording.
    public func reset() {
      lock.lock()
      defer { lock.unlock() }

      filterStates = Array(repeating: 0, count: configuration.bandCount)

      for i in 0..<configuration.bandCount {
        accumulators[i].removeAll(keepingCapacity: true)
        lodBands[i].minBuffer = Array(repeating: 0, count: configuration.lodBufferLength)
        lodBands[i].maxBuffer = Array(repeating: 0, count: configuration.lodBufferLength)
        lodBands[i].rmsBuffer = Array(repeating: 0, count: configuration.lodBufferLength)
      }

      lodWriteIndex = 0
      totalSamplesProcessed = 0

      os_log(.info, log: log, "Reset all buffers")
    }

    // MARK: - Diagnostics

    /// Current write index in the circular buffer.
    public var currentWriteIndex: Int {
      lock.lock()
      defer { lock.unlock() }
      return lodWriteIndex
    }

    /// Total number of raw samples processed.
    public var samplesProcessed: Int {
      lock.lock()
      defer { lock.unlock() }
      return totalSamplesProcessed
    }

    /// Approximate duration of audio processed in seconds.
    public var durationProcessed: TimeInterval {
      Double(samplesProcessed) / Double(configuration.sampleRate)
    }
  }

  // MARK: - Offline Generation

  extension MultiBandLODProcessor {
    /// Generate LOD data from an audio file.
    ///
    /// This processes the entire audio file and returns a snapshot suitable
    /// for static waveform rendering.
    ///
    /// - Parameters:
    ///   - url: URL of the audio file to process.
    ///   - configuration: LOD configuration to use.
    /// - Returns: Complete LOD snapshot of the audio file.
    public static func generateFromFile(
      url: URL,
      configuration: MultiBandLODConfiguration = .default
    ) async throws -> MultiBandLODSnapshot {
      let file = try AVFAudio.AVAudioFile(forReading: url)
      let processingFormat = file.processingFormat
      let totalFrames = AVFAudio.AVAudioFrameCount(file.length)

      // Adjust configuration for file duration
      let fileDuration = Double(file.length) / processingFormat.sampleRate
      let adjustedConfig = MultiBandLODConfiguration(
        bandCount: configuration.bandCount,
        lodRatio: configuration.lodRatio,
        bufferSeconds: max(Int(ceil(fileDuration)) + 1, configuration.bufferSeconds),
        sampleRate: Int(processingFormat.sampleRate),
        crossoverMode: configuration.crossoverMode
      )

      let processor = MultiBandLODProcessor(configuration: adjustedConfig)

      // Process in chunks
      let bufferSize: AVFAudio.AVAudioFrameCount = 4096
      guard
        let buffer = AVFAudio.AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: bufferSize
        )
      else {
        throw LODGenerationError.bufferCreationFailed
      }

      file.framePosition = 0
      var framesRemaining = totalFrames

      while framesRemaining > 0 {
        let framesToRead = min(bufferSize, framesRemaining)
        try file.read(into: buffer, frameCount: framesToRead)

        guard buffer.frameLength > 0 else { break }

        // If stereo, average channels
        if let channels = buffer.floatChannelData {
          let frameCount = Int(buffer.frameLength)
          let channelCount = Int(processingFormat.channelCount)

          if channelCount == 1 {
            processor.process(buffer)
          } else {
            // Average channels
            var monoBuffer = [Float](repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
              var sum: Float = 0
              for ch in 0..<channelCount {
                sum += channels[ch][frame]
              }
              monoBuffer[frame] = sum / Float(channelCount)
            }
            processor.process(monoBuffer)
          }
        }

        framesRemaining -= buffer.frameLength
      }

      return processor.snapshot()
    }

    /// Errors that can occur during LOD generation.
    public enum LODGenerationError: Error, LocalizedError {
      case bufferCreationFailed
      case invalidAudioFormat

      public var errorDescription: String? {
        switch self {
        case .bufferCreationFailed:
          return "Failed to create audio buffer for processing"
        case .invalidAudioFormat:
          return "Audio file has an unsupported format"
        }
      }
    }
  }

#endif
