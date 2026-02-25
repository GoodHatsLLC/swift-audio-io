#if canImport(AVFAudio)
  import AVFAudio
  public import Foundation
  public import Tools

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

      let snapshot = try await MultiBandLODProcessor.generateFromFile(
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
      let totalDuration = segments.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }

      let snapshot = try await MultiBandLODProcessor.generateFromFile(
        url: url, segments: segments, configuration: configuration)

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
  }
#endif
