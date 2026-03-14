// © GoodHatsLLC

#if canImport(AVFAudio)
  import AVFAudio
  public import Foundation
  import Tools

  /// Result of offline LOD extraction from an audio file.
  public struct OfflineLODResult: Sendable {
    /// The LOD snapshot data.
    public var snapshot: MultiBandLODSnapshot

    /// Number of frequency bands.
    public var bandCount: Int {
      snapshot.bandCount
    }

    /// Total duration of the extracted audio in seconds.
    public var durationSeconds: Double

    /// Sample rate of the source audio.
    public var sampleRate: Double

    public init(snapshot: MultiBandLODSnapshot, durationSeconds: Double, sampleRate: Double) {
      self.snapshot = snapshot
      self.durationSeconds = durationSeconds
      self.sampleRate = sampleRate
    }
  }

  /// Extracts LOD waveform data from audio files for offline rendering.
  public struct OfflineLODExtractor: Sendable {
    /// Strategy used to reduce multi-channel audio to mono for extraction.
    public enum ChannelStrategy: Sendable, Equatable {
      /// Average all channels equally.
      case average

      /// Use channel 0, or the only channel when mono.
      case left

      /// Use channel 1 when present, otherwise channel 0.
      case right

      /// Use a specific channel index, clamped to available channels.
      case channel(Int)

      /// Use per-channel weights for a custom mix-down.
      ///
      /// If fewer weights than channels are provided, missing weights default to 0.
      /// If all resolved weights are 0, extraction falls back to `.average`.
      case weighted([Float])

      fileprivate func directChannelIndex(channelCount: Int) -> Int? {
        guard channelCount > 0 else { return nil }
        switch self {
        case .left:
          return 0
        case .right:
          return min(1, channelCount - 1)
        case .channel(let requested):
          return min(max(requested, 0), channelCount - 1)
        case .average, .weighted:
          return nil
        }
      }
    }

    private static let maxOfflineLODSamplesPerBand = 16384
    private static let readBufferSize: AVAudioFrameCount = 4096

    public var configuration: MultiBandLODConfiguration
    public var channelStrategy: ChannelStrategy

    public init(
      configuration: MultiBandLODConfiguration = .default,
      channelStrategy: ChannelStrategy = .average,
    ) {
      self.configuration = configuration
      self.channelStrategy = channelStrategy
    }

    /// Extract LOD data from an entire audio file.
    public func extract(
      from url: URL,
    ) async throws(MultiBandLODProcessor.LODGenerationError) -> OfflineLODResult {
      try await extract(from: url, channelStrategy: channelStrategy)
    }

    /// Extract LOD data from an entire audio file with explicit channel strategy.
    public func extract(
      from url: URL,
      channelStrategy: ChannelStrategy,
    ) async throws(MultiBandLODProcessor.LODGenerationError) -> OfflineLODResult {
      let file = try openFile(at: url)
      let processingFormat = file.processingFormat
      let sampleRate = max(processingFormat.sampleRate, 1)
      let durationSeconds = Double(file.length) / sampleRate
      let fileFrameCount = max(Int(file.length), 0)

      let adjustedConfig = Self.adjustedConfiguration(
        base: configuration,
        totalFrames: fileFrameCount,
        sampleRate: sampleRate,
      )
      let processor = unsafe MultiBandLODProcessor(
        configuration: adjustedConfig,
        allocateRawStorage: false,
      )

      unsafe try processWholeFile(
        file,
        processingFormat: processingFormat,
        processor: processor,
        channelStrategy: channelStrategy,
        url: url,
      )
      unsafe processor.finalize()
      let snapshot = unsafe processor.snapshotLocking()

      return OfflineLODResult(
        snapshot: snapshot,
        durationSeconds: durationSeconds,
        sampleRate: sampleRate,
      )
    }

    /// Extract LOD data from specific segments of an audio file.
    public func extract(
      from url: URL,
      segments: [ClosedRange<TimeInterval>],
    ) async throws(MultiBandLODProcessor.LODGenerationError) -> OfflineLODResult {
      try await extract(from: url, segments: segments, channelStrategy: channelStrategy)
    }

    /// Extract LOD data from specific segments of an audio file with explicit channel strategy.
    public func extract(
      from url: URL,
      segments: [ClosedRange<TimeInterval>],
      channelStrategy: ChannelStrategy,
    ) async throws(MultiBandLODProcessor.LODGenerationError) -> OfflineLODResult {
      let file = try openFile(at: url)
      let processingFormat = file.processingFormat
      let sampleRate = max(processingFormat.sampleRate, 1)
      let fileDuration = Double(file.length) / sampleRate
      let normalizedSegments = Self.normalizeSegments(segments, fileDuration: fileDuration)

      guard !normalizedSegments.isEmpty else {
        return OfflineLODResult(
          snapshot: .empty,
          durationSeconds: 0,
          sampleRate: sampleRate,
        )
      }

      let segmentFrames = Self.segmentFrameRanges(for: normalizedSegments, sampleRate: sampleRate)
      let totalFrames = segmentFrames.reduce(0) { sum, range in
        sum + max(0, Int(max(AVAudioFramePosition(0), range.end - range.start)))
      }

      guard totalFrames > 0 else {
        return OfflineLODResult(
          snapshot: .empty,
          durationSeconds: 0,
          sampleRate: sampleRate,
        )
      }

      let adjustedConfig = Self.adjustedConfiguration(
        base: configuration,
        totalFrames: totalFrames,
        sampleRate: sampleRate,
      )
      let processor = unsafe MultiBandLODProcessor(
        configuration: adjustedConfig,
        allocateRawStorage: false,
      )

      unsafe try processSegmentRanges(
        file,
        processingFormat: processingFormat,
        segmentFrames: segmentFrames,
        processor: processor,
        channelStrategy: channelStrategy,
        url: url,
      )
      unsafe processor.finalize()
      let snapshot = unsafe processor.snapshotLocking()

      let totalDuration = normalizedSegments.reduce(0.0) { total, range in
        total + (range.upperBound - range.lowerBound)
      }

      return OfflineLODResult(
        snapshot: snapshot,
        durationSeconds: totalDuration,
        sampleRate: sampleRate,
      )
    }

    private static func adjustedConfiguration(
      base: MultiBandLODConfiguration,
      totalFrames: Int,
      sampleRate: Double,
    ) -> MultiBandLODConfiguration {
      let effectiveLodRatio: Int
      let (maxFramesAtBaseRatio, overflow) =
        maxOfflineLODSamplesPerBand.multipliedReportingOverflow(
          by: base.lodRatio,
        )
      if !overflow && totalFrames > maxFramesAtBaseRatio {
        effectiveLodRatio = max(
          base.lodRatio,
          Int(ceil(Double(totalFrames) / Double(maxOfflineLODSamplesPerBand))),
        )
      } else {
        effectiveLodRatio = base.lodRatio
      }

      let (paddedFrameCount, paddedOverflow) = totalFrames.addingReportingOverflow(
        max(effectiveLodRatio, 1),
      )
      let rawBufferLengthOverride = paddedOverflow ? totalFrames : paddedFrameCount
      let bufferSeconds = max(Int(ceil(Double(totalFrames) / max(sampleRate, 1))), 1)

      return MultiBandLODConfiguration(
        bandCount: base.bandCount,
        lodRatio: effectiveLodRatio,
        bufferSeconds: bufferSeconds,
        sampleRate: Int(max(sampleRate, 1)),
        crossoverMode: base.crossoverMode,
        snapshotSwapInterval: base.snapshotSwapInterval,
        rawBufferLengthOverride: rawBufferLengthOverride,
      )
    }

    private func processWholeFile(
      _ file: AVAudioFile,
      processingFormat: AVAudioFormat,
      processor: MultiBandLODProcessor,
      channelStrategy: ChannelStrategy,
      url: URL,
    ) throws(MultiBandLODProcessor.LODGenerationError) {
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: Self.readBufferSize,
        )
      else {
        throw .bufferCreationFailed
      }

      var monoScratch = [Float](repeating: 0, count: Int(Self.readBufferSize))
      file.framePosition = 0
      var framesRemaining = AVAudioFrameCount(file.length)

      while framesRemaining > 0 {
        let framesToRead = min(Self.readBufferSize, framesRemaining)
        do {
          try file.read(into: buffer, frameCount: framesToRead)
        } catch {
          throw .audioFileReadFailed(url: url, error: ErrorContext(error))
        }

        guard buffer.frameLength > 0 else { break }
        unsafe try Self.processBuffer(
          buffer,
          processingFormat: processingFormat,
          processor: processor,
          channelStrategy: channelStrategy,
          monoScratch: &monoScratch,
        )
        framesRemaining -= buffer.frameLength
      }
    }

    private func processSegmentRanges(
      _ file: AVAudioFile,
      processingFormat: AVAudioFormat,
      segmentFrames: [(start: AVAudioFramePosition, end: AVAudioFramePosition)],
      processor: MultiBandLODProcessor,
      channelStrategy: ChannelStrategy,
      url: URL,
    ) throws(MultiBandLODProcessor.LODGenerationError) {
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: Self.readBufferSize,
        )
      else {
        throw .bufferCreationFailed
      }

      var monoScratch = [Float](repeating: 0, count: Int(Self.readBufferSize))

      for frameRange in segmentFrames {
        var framesRemaining = max(AVAudioFramePosition(0), frameRange.end - frameRange.start)
        file.framePosition = frameRange.start

        while framesRemaining > 0 {
          let framesToRead = min(Self.readBufferSize, AVAudioFrameCount(framesRemaining))
          do {
            try file.read(into: buffer, frameCount: framesToRead)
          } catch {
            throw .audioFileReadFailed(url: url, error: ErrorContext(error))
          }

          guard buffer.frameLength > 0 else { break }
          unsafe try Self.processBuffer(
            buffer,
            processingFormat: processingFormat,
            processor: processor,
            channelStrategy: channelStrategy,
            monoScratch: &monoScratch,
          )
          framesRemaining -= AVAudioFramePosition(buffer.frameLength)
        }
      }
    }

    private static func processBuffer(
      _ buffer: AVAudioPCMBuffer,
      processingFormat: AVAudioFormat,
      processor: MultiBandLODProcessor,
      channelStrategy: ChannelStrategy,
      monoScratch: inout [Float],
    ) throws(MultiBandLODProcessor.LODGenerationError) {
      guard buffer.frameLength > 0 else { return }
      guard let channels = unsafe buffer.floatChannelData else {
        throw .invalidAudioFormat
      }

      let frameCount = Int(buffer.frameLength)
      let channelCount = Int(processingFormat.channelCount)
      guard channelCount > 0 else { throw .invalidAudioFormat }

      if channelCount == 1 {
        unsafe processor.process(buffer)
        return
      }

      if let directChannel = channelStrategy.directChannelIndex(channelCount: channelCount) {
        let selected = unsafe UnsafeBufferPointer(
          start: channels[directChannel],
          count: frameCount,
        )
        unsafe processor.process(selected)
        return
      }

      if monoScratch.count < frameCount {
        monoScratch = Array(repeating: 0, count: frameCount)
      }

      switch channelStrategy {
      case .average:
        let invChannelCount = 1.0 / Float(channelCount)
        for frame in 0..<frameCount {
          var sum: Float = 0
          for channel in 0..<channelCount {
            unsafe sum += channels[channel][frame]
          }
          monoScratch[frame] = sum * invChannelCount
        }
      case .weighted(let weights):
        let resolvedWeights = resolvedMixWeights(weights, channelCount: channelCount)
        for frame in 0..<frameCount {
          var sum: Float = 0
          for channel in 0..<channelCount {
            unsafe sum += channels[channel][frame] * resolvedWeights[channel]
          }
          monoScratch[frame] = sum
        }
      case .left, .right, .channel:
        // Already handled by directChannelIndex; this fallback keeps switch exhaustive.
        for frame in 0..<frameCount {
          unsafe monoScratch[frame] = channels[0][frame]
        }
      }

      unsafe monoScratch.withUnsafeBufferPointer { mono in
        let monoSlice = unsafe UnsafeBufferPointer(start: mono.baseAddress, count: frameCount)
        unsafe processor.process(monoSlice)
      }
    }

    private static func resolvedMixWeights(_ weights: [Float], channelCount: Int) -> [Float] {
      guard channelCount > 0 else { return [] }
      if weights.isEmpty {
        return Array(repeating: 1.0 / Float(channelCount), count: channelCount)
      }

      var resolved = Array(repeating: Float(0), count: channelCount)
      for index in 0..<channelCount where index < weights.count {
        resolved[index] = weights[index]
      }

      let energy = resolved.reduce(Float(0)) { $0 + abs($1) }
      guard energy > Float.ulpOfOne else {
        return Array(repeating: 1.0 / Float(channelCount), count: channelCount)
      }
      return resolved.map { $0 / energy }
    }

    private func openFile(
      at url: URL,
    ) throws(MultiBandLODProcessor.LODGenerationError) -> AVAudioFile {
      do {
        return try AVAudioFile(forReading: url)
      } catch {
        throw .audioFileOpenFailed(url: url, error: ErrorContext(error))
      }
    }

    private static func segmentFrameRanges(
      for segments: [ClosedRange<TimeInterval>],
      sampleRate: Double,
    ) -> [(start: AVAudioFramePosition, end: AVAudioFramePosition)] {
      segments.compactMap { range in
        let start = max(
          AVAudioFramePosition(0), AVAudioFramePosition(range.lowerBound * sampleRate),
        )
        let end = max(start, AVAudioFramePosition(range.upperBound * sampleRate))
        guard end > start else { return nil }
        return (start: start, end: end)
      }
    }

    private static func normalizeSegments(
      _ segments: [ClosedRange<TimeInterval>],
      fileDuration: TimeInterval,
    ) -> [ClosedRange<TimeInterval>] {
      segments.compactMap { range in
        let lower = max(0, min(range.lowerBound, range.upperBound))
        let upper = max(0, max(range.lowerBound, range.upperBound))
        let clampedLower = min(lower, fileDuration)
        let clampedUpper = min(max(clampedLower, upper), fileDuration)
        guard clampedUpper > clampedLower else { return nil }
        return clampedLower...clampedUpper
      }
    }
  }
#endif
