#if canImport(AVFAudio)
  import AVFAudio
  public import Foundation
  import Tools

  /// Result of offline LOD extraction from an audio file.
  public struct OfflineLODResult: Sendable {
    /// The LOD snapshot data.
    public var snapshot: MultiBandLODSnapshot

    /// Number of frequency bands.
    public var bandCount: Int { snapshot.bandCount }

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
  ///
  /// Wraps `MultiBandLODProcessor.generateFromFile` with a cleaner API.
  public struct OfflineLODExtractor: Sendable {
    public var configuration: MultiBandLODConfiguration

    public init(configuration: MultiBandLODConfiguration = .default) {
      self.configuration = configuration
    }

    /// Extract LOD data from an entire audio file.
    public func extract(
      from url: URL
    ) async throws(MultiBandLODProcessor.LODGenerationError) -> OfflineLODResult {
      let file = try openFile(at: url)
      let sampleRate = max(file.processingFormat.sampleRate, 1)
      let durationSeconds = Double(file.length) / sampleRate

      let snapshot = unsafe try await MultiBandLODProcessor.generateFromFile(
        url: url, configuration: configuration)

      return OfflineLODResult(
        snapshot: snapshot,
        durationSeconds: durationSeconds,
        sampleRate: sampleRate
      )
    }

    /// Extract LOD data from specific segments of an audio file.
    public func extract(
      from url: URL,
      segments: [ClosedRange<TimeInterval>]
    ) async throws(MultiBandLODProcessor.LODGenerationError) -> OfflineLODResult {
      let file = try openFile(at: url)
      let sampleRate = max(file.processingFormat.sampleRate, 1)
      let fileDuration = Double(file.length) / sampleRate
      let normalizedSegments = Self.normalizeSegments(
        segments,
        fileDuration: fileDuration
      )

      if normalizedSegments.isEmpty {
        return OfflineLODResult(
          snapshot: .empty,
          durationSeconds: 0,
          sampleRate: sampleRate
        )
      }

      let snapshot = unsafe try await MultiBandLODProcessor.generateFromFile(
        url: url,
        segments: normalizedSegments,
        configuration: configuration
      )
      let totalDuration = normalizedSegments.reduce(0.0) { total, range in
        total + (range.upperBound - range.lowerBound)
      }

      return OfflineLODResult(
        snapshot: snapshot,
        durationSeconds: totalDuration,
        sampleRate: sampleRate
      )
    }

    private func openFile(
      at url: URL
    ) throws(MultiBandLODProcessor.LODGenerationError) -> AVAudioFile {
      do {
        return try AVAudioFile(forReading: url)
      } catch {
        throw .audioFileOpenFailed(url: url, error: ErrorContext(error))
      }
    }

    private static func normalizeSegments(
      _ segments: [ClosedRange<TimeInterval>],
      fileDuration: TimeInterval
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
