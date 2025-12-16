#if canImport(AVFAudio)
  import Atomics
  import AVFAudio
  import Foundation
  import os

  private let log = OSLog(subsystem: "AIOEngine", category: "MultiBandLOD")

  // MARK: - Triple-Buffered LOD Storage

  /// Pre-allocated storage for one complete LOD buffer set.
  ///
  /// ## Thread Safety
  ///
  /// This class is marked `@unchecked Sendable` because thread safety is guaranteed
  /// by the triple-buffering protocol in `MultiBandLODProcessor`, NOT by internal
  /// synchronization. The safety invariants are:
  ///
  /// 1. **Single writer**: Only the audio thread writes to slots, protected by `lock`
  /// 2. **Slot rotation**: The processor maintains 3 slots that rotate through states:
  ///    - Writing: Audio thread actively mutates this slot
  ///    - Current: Published for readers via atomic index, never written
  ///    - Retiring: Previous current, may still be read, never written
  /// 3. **Atomic publication**: `currentSlotIndex` is updated atomically after writes complete
  ///
  /// **Do not** access `LODBufferSlot` directly outside of `MultiBandLODProcessor`.
  /// Use `snapshotRef()` to obtain a safe `LODSnapshotRef` for reading.
  final class LODBufferSlot: @unchecked Sendable {
    let bands: [MutableBandBuffers]
    var writeIndex: Int = 0
    let lodRatio: Int
    let rawBufferLength: Int
    let bandCount: Int

    /// Mutable band buffer storage - arrays are pre-allocated and mutated in place.
    ///
    /// Thread safety is provided by the parent `LODBufferSlot`'s triple-buffer protocol.
    /// See `LODBufferSlot` documentation for safety invariants.
    final class MutableBandBuffers {
      let bandIndex: Int
      var minBuffer: ContiguousArray<Float>
      var maxBuffer: ContiguousArray<Float>
      var rmsBuffer: ContiguousArray<Float>

      init(bandIndex: Int, capacity: Int) {
        self.bandIndex = bandIndex
        self.minBuffer = ContiguousArray(repeating: 0, count: capacity)
        self.maxBuffer = ContiguousArray(repeating: 0, count: capacity)
        self.rmsBuffer = ContiguousArray(repeating: 0, count: capacity)
      }

      func reset() {
        for i in minBuffer.indices {
          minBuffer[i] = 0
          maxBuffer[i] = 0
          rmsBuffer[i] = 0
        }
      }
    }

    init(configuration: MultiBandLODConfiguration) {
      self.lodRatio = configuration.lodRatio
      self.rawBufferLength = configuration.rawBufferLength
      self.bandCount = configuration.bandCount
      self.bands = (0..<configuration.bandCount).map { bandIndex in
        MutableBandBuffers(bandIndex: bandIndex, capacity: configuration.lodBufferLength)
      }
    }

    func reset() {
      writeIndex = 0
      for band in bands {
        band.reset()
      }
    }

    /// Creates a snapshot by copying data (use sparingly, e.g., for file export).
    func toSnapshot() -> MultiBandLODSnapshot {
      MultiBandLODSnapshot(
        bands: bands.map { band in
          BandLODData(
            bandIndex: band.bandIndex,
            minBuffer: Array(band.minBuffer),
            maxBuffer: Array(band.maxBuffer),
            rmsBuffer: Array(band.rmsBuffer)
          )
        },
        writeIndex: writeIndex,
        lodRatio: lodRatio,
        rawBufferLength: rawBufferLength
      )
    }
  }

  // MARK: - Zero-Copy Snapshot Reference

  /// A reference to LOD data for GPU rendering.
  ///
  /// This class provides access to pre-allocated buffers. Per-band access via
  /// `withMinBuffer(band:)` etc. is zero-copy. Flat buffer access via
  /// `copyFlatMinBuffer()` etc. requires allocation (bands aren't contiguous).
  ///
  /// ## Thread Safety
  ///
  /// This class is marked `@unchecked Sendable` because safety is guaranteed by
  /// the triple-buffering protocol. The slot referenced here is either "current"
  /// or "retiring" - never the one being written to. This is enforced by:
  ///
  /// 1. `snapshotRef()` reads `currentSlotIndex` with acquire ordering
  /// 2. The audio thread only writes to `writeSlotIndex`, never `currentSlotIndex`
  /// 3. Slot swaps atomically publish the write slot as current
  ///
  /// The reference is safe to use for the duration of a frame. Do not cache
  /// `LODSnapshotRef` across frames; always call `snapshotRef()` each frame.
  ///
  /// ## Usage
  ///
  /// ```swift
  /// let ref = processor.snapshotRef()
  ///
  /// // Zero-copy per-band access (preferred for Metal)
  /// for band in 0..<ref.bandCount {
  ///   ref.withMinBuffer(band: band) { ptr in
  ///     metalBuffer.contents().copyMemory(from: ptr.baseAddress!, byteCount: ...)
  ///   }
  /// }
  ///
  /// // Allocating flat access (convenience for simple cases)
  /// ref.copyFlatMinBuffer { ptr in
  ///   // ptr contains all bands concatenated
  /// }
  /// ```
  public struct LODSnapshotRef: @unchecked Sendable, SnapshotProvider, LODSnapshot {
    fileprivate let slot: LODBufferSlot

    fileprivate init(_ slot: LODBufferSlot) {
      self.slot = slot
    }

    public var bandCount: Int { slot.bandCount }
    public var writeIndex: Int { slot.writeIndex }
    public var lodRatio: Int { slot.lodRatio }
    public var rawBufferLength: Int { slot.rawBufferLength }
    public var lodBufferLength: Int { slot.bands.first?.minBuffer.count ?? 0 }

    /// Direct access to a band's min buffer.
    public func withMinBuffer<R>(band: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      slot.bands[band].minBuffer.withUnsafeBufferPointer(body)
    }

    /// Direct access to a band's max buffer.
    public func withMaxBuffer<R>(band: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      slot.bands[band].maxBuffer.withUnsafeBufferPointer(body)
    }

    /// Direct access to a band's RMS buffer.
    public func withRMSBuffer<R>(band: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      slot.bands[band].rmsBuffer.withUnsafeBufferPointer(body)
    }

    /// Creates a flat copy of min buffers for all bands (for GPU upload).
    ///
    /// - Note: This method **allocates** a temporary array. For zero-copy access,
    ///   use `withMinBuffer(band:)` to upload each band separately.
    /// - Parameter body: Closure receiving the flat buffer pointer.
    /// - Returns: The result of the body closure.
    public func copyFlatMinBuffer<R>(_ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      let flat = slot.bands.flatMap { Array($0.minBuffer) }
      return flat.withUnsafeBufferPointer(body)
    }

    /// Creates a flat copy of max buffers for all bands (for GPU upload).
    ///
    /// - Note: This method **allocates** a temporary array. For zero-copy access,
    ///   use `withMaxBuffer(band:)` to upload each band separately.
    public func copyFlatMaxBuffer<R>(_ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      let flat = slot.bands.flatMap { Array($0.maxBuffer) }
      return flat.withUnsafeBufferPointer(body)
    }

    /// Creates a flat copy of RMS buffers for all bands (for GPU upload).
    ///
    /// - Note: This method **allocates** a temporary array. For zero-copy access,
    ///   use `withRMSBuffer(band:)` to upload each band separately.
    public func copyFlatRMSBuffer<R>(_ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      let flat = slot.bands.flatMap { Array($0.rmsBuffer) }
      return flat.withUnsafeBufferPointer(body)
    }

    /// Convert to a copying snapshot (for compatibility or file export).
    public func toSnapshot() -> MultiBandLODSnapshot? {
      slot.toSnapshot()
    }
  }

public protocol SnapshotProvider {
    func toSnapshot() -> MultiBandLODSnapshot?
}

  // MARK: - MultiBandLODProcessor

  /// Processes audio samples into multi-band Level-of-Detail data for GPU visualization.
  ///
  /// This processor implements:
  /// 1. Cascading lowpass filter bank to split audio into frequency bands
  /// 2. LOD reduction (e.g., 128:1) computing min/max/RMS per window
  /// 3. Circular buffer storage for streaming visualization
  ///
  /// Uses triple-buffering to provide lock-free snapshot access for 60fps rendering.
  /// The render thread can always read a consistent snapshot without blocking on audio processing.
  public final class MultiBandLODProcessor: @unchecked Sendable {

    // MARK: - Configuration

    private let configuration: MultiBandLODConfiguration
    private let crossoverAlphas: [Float]

    // MARK: - State (Single-writer: audio thread)

    /// Filter states for cascading lowpass (one per band)
    private var filterStates: [Float]

    private struct RunningStats {
      var minV: Float = 0
      var maxV: Float = 0
      var sumSq: Float = 0
      var count: Int = 0

      mutating func reset() {
        minV = 0
        maxV = 0
        sumSq = 0
        count = 0
      }

      mutating func add(_ v: Float) {
        if count == 0 {
          minV = v
          maxV = v
          sumSq = v * v
          count = 1
          return
        }
        if v < minV { minV = v }
        if v > maxV { maxV = v }
        sumSq += (v * v)
        count += 1
      }
    }

    /// Per-band running stats for LOD computation (current window).
    private var windowStats: [RunningStats]

    /// Total samples processed.
    private let totalSamplesProcessed: ManagedAtomic<Int>

    #if DEBUG
      /// Duration of the most recent `process(_:)` call (nanoseconds).
      private let debugLastProcessDurationNs: ManagedAtomic<UInt64>
    #endif

    // MARK: - Triple-Buffered Snapshot (Lock-free read access)

    /// Three pre-allocated buffer slots for triple buffering.
    /// Slot 0, 1, 2 rotate through: writing → current → retiring
    private let bufferSlots: [LODBufferSlot]

    /// Index of the slot currently being written to (only audio thread accesses).
    private var writeSlotIndex: Int = 0

    /// Index of the slot that's "retiring" (previously current, may still be read).
    /// This slot is never written to; it becomes the next write slot after a publish.
    private var retiringSlotIndex: Int = 2

    /// Index of the slot that's current for reading (atomic for lock-free access).
    private let currentSlotIndex: ManagedAtomic<Int>

    /// Counter for LOD commits since last slot swap.
    private var commitsSinceSlotSwap: Int = 0

    /// Number of LOD commits between slot swaps (configurable).
    private let slotSwapInterval: Int

    /// Write index at the start of the current publish interval.
    /// Used to copy only the delta indices into the next write slot.
    private var deltaStartWriteIndex: Int = 0

    /// Number of LOD indices written since the last publish.
    private var deltaWrittenCount: Int = 0

    /// Direct reference to write slot's bands for fast access.
    private var writeSlot: LODBufferSlot { bufferSlots[writeSlotIndex] }

    /// The writer's current write index (diagnostics only).
    private let writerWriteIndexAtomic: ManagedAtomic<Int>

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

      self.windowStats = Array(repeating: RunningStats(), count: configuration.bandCount)
      self.totalSamplesProcessed = ManagedAtomic(0)
      #if DEBUG
        self.debugLastProcessDurationNs = ManagedAtomic(0)
      #endif

      // Initialize triple-buffered LOD slots (pre-allocated, never reallocated)
      self.bufferSlots = [
        LODBufferSlot(configuration: configuration),
        LODBufferSlot(configuration: configuration),
        LODBufferSlot(configuration: configuration),
      ]

      // Slot 0 starts as write, slot 1 starts as current for reading, slot 2 is retiring.
      self.writeSlotIndex = 0
      self.currentSlotIndex = ManagedAtomic(1)
      self.retiringSlotIndex = 2
      self.slotSwapInterval = configuration.snapshotSwapInterval
      self.deltaStartWriteIndex = bufferSlots[writeSlotIndex].writeIndex
      self.deltaWrittenCount = 0
      self.writerWriteIndexAtomic = ManagedAtomic(bufferSlots[writeSlotIndex].writeIndex)

      os_log(
        .info, log: log,
        "Initialized with %d bands, LOD ratio %d, buffer %d seconds (triple-buffered)",
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

      #if DEBUG
        let startNs = DispatchTime.now().uptimeNanoseconds
      #endif
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

          windowStats[b].add(part)
        }

        // Check if we have enough samples for an LOD commit
        if windowStats[0].count >= lodRatio {
          commitLOD()
        }
      }

      totalSamplesProcessed.wrappingIncrement(by: samples.count, ordering: .relaxed)

      #if DEBUG
        debugLastProcessDurationNs.store(
          DispatchTime.now().uptimeNanoseconds - startNs,
          ordering: .relaxed
        )
      #endif
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
      // Write directly to pre-allocated triple-buffered slot (zero allocation)
      let slot = writeSlot
      let wIdx = slot.writeIndex
      let bandCount = configuration.bandCount

      for b in 0..<bandCount {
        let stats = windowStats[b]
        guard stats.count > 0 else { continue }
        let count = Float(stats.count)

        // Write directly to pre-allocated buffers (no allocation)
        slot.bands[b].minBuffer[wIdx] = stats.minV
        slot.bands[b].maxBuffer[wIdx] = stats.maxV
        slot.bands[b].rmsBuffer[wIdx] = sqrt(stats.sumSq / count)
      }

      slot.writeIndex = (wIdx + 1) % configuration.lodBufferLength
      deltaWrittenCount += 1
      writerWriteIndexAtomic.store(slot.writeIndex, ordering: .relaxed)

      for i in windowStats.indices {
        windowStats[i].reset()
      }

      // Periodically swap slots for lock-free reading (~60fps)
      commitsSinceSlotSwap += 1
      if commitsSinceSlotSwap >= slotSwapInterval {
        commitsSinceSlotSwap = 0
        swapSlots()
      }
    }

    /// Swaps the write slot to become current, picks a new write slot.
    /// Called periodically from commitLOD while holding the lock.
    private func swapSlots() {
      // Current slot is safe for readers; write slot contains freshly committed data.
      let oldCurrent = currentSlotIndex.load(ordering: .acquiring)
      let oldWrite = writeSlotIndex
      let oldRetiring = retiringSlotIndex

      let newCurrent = oldWrite
      let newRetiring = oldCurrent
      let newWrite = oldRetiring

      let publishedSlot = bufferSlots[newCurrent]
      let nextWriteSlot = bufferSlots[newWrite]

      // Copy only the indices written since the last publish into the next write slot,
      // so when it later becomes current it contains a coherent history buffer.
      copyDeltaIndices(
        from: publishedSlot,
        to: nextWriteSlot,
        startWriteIndex: deltaStartWriteIndex,
        count: deltaWrittenCount
      )

      // Continue writing at the same circular index.
      nextWriteSlot.writeIndex = publishedSlot.writeIndex

      // Atomically publish the new current slot.
      currentSlotIndex.store(newCurrent, ordering: .releasing)

      // Rotate roles.
      retiringSlotIndex = newRetiring
      writeSlotIndex = newWrite

      // Next publish interval starts at the current write index.
      deltaStartWriteIndex = nextWriteSlot.writeIndex
      deltaWrittenCount = 0
      writerWriteIndexAtomic.store(nextWriteSlot.writeIndex, ordering: .relaxed)
    }

    private func copyDeltaIndices(
      from source: LODBufferSlot,
      to destination: LODBufferSlot,
      startWriteIndex: Int,
      count: Int
    ) {
      let lodLength = configuration.lodBufferLength
      guard lodLength > 0 else { return }

      let copyCount = min(max(count, 0), lodLength)
      guard copyCount > 0 else { return }

      if count >= lodLength {
        for idx in 0..<lodLength {
          for b in 0..<configuration.bandCount {
            destination.bands[b].minBuffer[idx] = source.bands[b].minBuffer[idx]
            destination.bands[b].maxBuffer[idx] = source.bands[b].maxBuffer[idx]
            destination.bands[b].rmsBuffer[idx] = source.bands[b].rmsBuffer[idx]
          }
        }
      } else {
        var idx = startWriteIndex % lodLength
        if idx < 0 { idx += lodLength }

        for _ in 0..<copyCount {
          for b in 0..<configuration.bandCount {
            destination.bands[b].minBuffer[idx] = source.bands[b].minBuffer[idx]
            destination.bands[b].maxBuffer[idx] = source.bands[b].maxBuffer[idx]
            destination.bands[b].rmsBuffer[idx] = source.bands[b].rmsBuffer[idx]
          }
          idx += 1
          if idx == lodLength { idx = 0 }
        }
      }
    }

    // MARK: - Snapshot

    /// Returns a zero-copy reference to current LOD data for rendering.
    ///
    /// This method is lock-free and returns a reference to pre-allocated buffers.
    /// No memory allocation or copying occurs. The returned reference is safe to use
    /// for rendering because triple-buffering guarantees the audio thread won't
    /// write to this slot while it's current.
    ///
    /// - Returns: Zero-copy reference to LOD data for GPU rendering.
    public func snapshotRef() -> LODSnapshotRef {
      let index = currentSlotIndex.load(ordering: .acquiring)
      return LODSnapshotRef(bufferSlots[index])
    }

    /// Creates a snapshot of current LOD data for rendering.
    ///
    /// This method is lock-free but does create a copy of the data.
    /// For zero-copy access, use `snapshotRef()` instead.
    ///
    /// - Returns: Complete LOD snapshot ready for GPU rendering.
    public func snapshot() -> MultiBandLODSnapshot {
      let index = currentSlotIndex.load(ordering: .acquiring)
      return bufferSlots[index].toSnapshot()
    }

    /// Creates a snapshot with explicit locking (for diagnostics).
    ///
    /// Use this method only when you need the absolute latest data
    /// and can tolerate potential blocking.
    ///
    /// - Returns: Most up-to-date LOD snapshot.
    public func snapshotLocking() -> MultiBandLODSnapshot {
      return writeSlot.toSnapshot()
    }

    // MARK: - Reset

    /// Resets all buffers and filter states.
    ///
    /// Call this when starting a new recording.
    public func reset() {
      filterStates = Array(repeating: 0, count: configuration.bandCount)

      for i in windowStats.indices {
        windowStats[i].reset()
      }

      // Reset all triple-buffered slots (in-place, no allocation)
      for slot in bufferSlots {
        slot.reset()
      }

      // Reset slot indices
      writeSlotIndex = 0
      currentSlotIndex.store(1, ordering: .releasing)
      retiringSlotIndex = 2
      commitsSinceSlotSwap = 0
      deltaStartWriteIndex = bufferSlots[writeSlotIndex].writeIndex
      deltaWrittenCount = 0
      totalSamplesProcessed.store(0, ordering: .relaxed)
      writerWriteIndexAtomic.store(bufferSlots[writeSlotIndex].writeIndex, ordering: .relaxed)

      os_log(.info, log: log, "Reset all buffers (triple-buffered)")
    }

    // MARK: - Diagnostics

    /// The published write index (safe for renderers).
    public var publishedWriteIndex: Int {
      let index = currentSlotIndex.load(ordering: .acquiring)
      return bufferSlots[index].writeIndex
    }

    /// The writer's current write index (diagnostics only).
    public var writerWriteIndex: Int {
      writerWriteIndexAtomic.load(ordering: .relaxed)
    }

    /// Current write index in the circular buffer.
    ///
    /// This is the published write index (safe for renderers).
    public var currentWriteIndex: Int { publishedWriteIndex }

    /// Total number of raw samples processed.
    public var samplesProcessed: Int {
      totalSamplesProcessed.load(ordering: .relaxed)
    }

    #if DEBUG
      /// Duration of the most recent `process(_:)` call, in nanoseconds.
      public var lastProcessDurationNanoseconds: UInt64 {
        debugLastProcessDurationNs.load(ordering: .relaxed)
      }
    #endif

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

      // Adjust configuration for the file, using the *exact* frame count for buffer sizing.
      // This avoids padding up to whole seconds (or a default live buffer size), which can
      // otherwise make offline waveforms look "chunky" and allow panning into empty space.
      let fileFrameCount = max(Int(file.length), 0)
      let (paddedFrameCount, paddedOverflow) = fileFrameCount.addingReportingOverflow(
        max(configuration.lodRatio, 1)
      )
      // Ensure offline buffers have at least one extra LOD slot so `writeIndex` doesn't wrap.
      // This keeps offline `writeIndex` monotonic (useful for sizing and mapping) while still
      // allowing us to commit the final partial window.
      let rawBufferLengthOverride = paddedOverflow ? fileFrameCount : paddedFrameCount
      let sampleRate = max(processingFormat.sampleRate, 1)
      let fileDuration = Double(file.length) / sampleRate
      let adjustedConfig = MultiBandLODConfiguration(
        bandCount: configuration.bandCount,
        lodRatio: configuration.lodRatio,
        bufferSeconds: max(Int(ceil(fileDuration)), 1),
        sampleRate: Int(sampleRate),
        crossoverMode: configuration.crossoverMode,
        snapshotSwapInterval: configuration.snapshotSwapInterval,
        rawBufferLengthOverride: rawBufferLengthOverride
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

      // Ensure the final partial interval is included even if it didn't reach a full LOD window.
      if processor.windowStats.first?.count ?? 0 > 0 {
        processor.commitLOD()
      }

      return processor.snapshotLocking()
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

  // MARK: - BandLODData Extension

  extension BandLODData {
    /// Creates a band LOD data container with explicit buffer data.
    ///
    /// - Parameters:
    ///   - bandIndex: Index of this band.
    ///   - minBuffer: Pre-populated minimum values.
    ///   - maxBuffer: Pre-populated maximum values.
    ///   - rmsBuffer: Pre-populated RMS values.
    init(bandIndex: Int, minBuffer: [Float], maxBuffer: [Float], rmsBuffer: [Float]) {
      self.bandIndex = bandIndex
      self.minBuffer = minBuffer
      self.maxBuffer = maxBuffer
      self.rmsBuffer = rmsBuffer
    }
  }

#endif
