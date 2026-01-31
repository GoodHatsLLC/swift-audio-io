#if canImport(AVFAudio)
  import Atomics
  import AVFAudio
  import Foundation
  import os
  import Tools

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

  // MARK: - Raw Band Storage

  /// Shared storage for raw audio samples (single circular buffer per band).
  ///
  /// This storage is shared across all snapshots and updated lock-free by the audio thread.
  /// Readers (render thread) read from `buffers` up to `rawWriteIndex`.
  final class RawBandStorage: @unchecked Sendable {
    let memory: UnsafeMutableBufferPointer<Float>
    let buffers: [UnsafeMutableBufferPointer<Float>]
    let length: Int
    let bandCount: Int

    init(bandCount: Int, length: Int) {
      self.bandCount = bandCount
      self.length = length
      let totalCount = bandCount * length
      self.memory = UnsafeMutableBufferPointer<Float>.allocate(capacity: totalCount)
      self.memory.initialize(repeating: 0)

      var slices: [UnsafeMutableBufferPointer<Float>] = []
      for i in 0..<bandCount {
        let start = i * length
        // Create a slice (view) into the memory
        let slice = UnsafeMutableBufferPointer(start: memory.baseAddress! + start, count: length)
        slices.append(slice)
      }
      self.buffers = slices
    }

    deinit {
      memory.deallocate()
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
    fileprivate let rawStorage: RawBandStorage?
    public let rawWriteIndexSnapshot: Int

    fileprivate init(
      _ slot: LODBufferSlot, rawStorage: RawBandStorage? = nil, rawWriteIndex: Int = 0
    ) {
      self.slot = slot
      self.rawStorage = rawStorage
      self.rawWriteIndexSnapshot = rawWriteIndex
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

    /// Direct access to a band's raw buffer.
    public func withRawBuffer<R>(band: Int, _ body: (UnsafeBufferPointer<Float>) -> R) -> R {
      guard let storage = rawStorage, band < storage.buffers.count else {
        return body(UnsafeBufferPointer(start: nil, count: 0))
      }
      return body(UnsafeBufferPointer(storage.buffers[band]))
    }

    /// Access the flat contiguous raw buffer (containing all bands).
    /// Used for single-copy upload to GPU.
    public func withFlatRawBuffer<R>(_ body: (UnsafeBufferPointer<Float>?) -> R) -> R {
      guard let storage = rawStorage else { return body(nil) }
      return body(UnsafeBufferPointer(storage.memory))
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
    private let filterCoefficients: [BiquadCoefficients]

    // MARK: - Filter Types

    private struct BiquadCoefficients: Sendable {
      let b0, b1, b2, a1, a2: Float
    }

    private struct BiquadState: Sendable {
      var x1: Float = 0
      var x2: Float = 0
      var y1: Float = 0
      var y2: Float = 0

      mutating func reset() {
        x1 = 0
        x2 = 0
        y1 = 0
        y2 = 0
      }
    }

    // MARK: - State (Single-writer: audio thread)

    /// Filter states for cascading lowpass (one per crossover)
    private var filterStates: [BiquadState]

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

    /// Raw band storage (single circular buffer per band).
    private let rawBandStorage: RawBandStorage

    /// Current write index for raw storage (atomic).
    private let rawWriteIndex: ManagedAtomic<Int>

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

      // Compute crossover frequencies
      let frequencies = configuration.crossoverMode.computeCrossoverFrequencies(
        bandCount: configuration.bandCount,
        sampleRate: configuration.sampleRate
      )

      // Calculate Biquad coefficients for each crossover (Linkwitz-Riley 2nd Order Lowpass)
      // LR2 = Q of 0.5
      self.filterCoefficients = frequencies.map { freq in
        let w0 = 2.0 * Float.pi * freq / Float(configuration.sampleRate)
        let cosW = cos(w0)
        let sinW = sin(w0)
        let Q: Float = 0.5
        let alpha = sinW / (2.0 * Q)

        let a0 = 1.0 + alpha
        let b0 = (1.0 - cosW) / 2.0
        let b1 = 1.0 - cosW
        let b2 = (1.0 - cosW) / 2.0
        let a1 = -2.0 * cosW
        let a2 = 1.0 - alpha

        return BiquadCoefficients(
          b0: b0 / a0,
          b1: b1 / a0,
          b2: b2 / a0,
          a1: a1 / a0,
          a2: a2 / a0
        )
      }

      // Initialize filter states (one per crossover)
      // Note: frequencies.count is bandCount - 1
      self.filterStates = Array(repeating: BiquadState(), count: frequencies.count)

      self.windowStats = Array(repeating: RunningStats(), count: configuration.bandCount)
      self.rawBandStorage = RawBandStorage(
        bandCount: configuration.bandCount,
        length: configuration.rawBufferLength
      )
      self.rawWriteIndex = ManagedAtomic(0)

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

      // Cache pointer to unsafe buffer for tight loop access if needed,
      // but UnsafeBufferPointer subscript is already efficient.
      let rawLength = configuration.rawBufferLength
      // Get current raw write index
      var currentRawWriteIndex = rawWriteIndex.load(ordering: .relaxed)

      for i in 0..<samples.count {
        let x = samples[i]

        // Cascading lowpass filter bank (Linkwitz-Riley 2nd Order)
        // Each band gets: (lowpass at cutoff) - (lowpass at previous cutoff)
        // Final band gets: input - (lowpass at highest cutoff)
        var lowerBoundSignal: Float = 0

        for b in 0..<bandCount {
          let part: Float
          if b == bandCount - 1 {
            // Highest band: everything above the last crossover
            part = x - lowerBoundSignal
          } else {
            // Apply Biquad lowpass filter
            let coeffs = filterCoefficients[b]
            // We use `withUnsafeMutablePointer` or just direct access since strict aliasing isn't an issue here with structs.
            // Direct access to struct members in array is fast.

            var state = filterStates[b]

            // Direct Form 1:
            // y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
            let lp =
              coeffs.b0 * x + coeffs.b1 * state.x1 + coeffs.b2 * state.x2
              - coeffs.a1 * state.y1 - coeffs.a2 * state.y2

            // Shift state
            state.x2 = state.x1
            state.x1 = x
            state.y2 = state.y1
            state.y1 = lp

            filterStates[b] = state  // Write back

            // This band's contribution
            part = lp - lowerBoundSignal
            lowerBoundSignal = lp
          }

          windowStats[b].add(part)

          // Write to raw buffer
          rawBandStorage.buffers[b][currentRawWriteIndex] = part
        }

        currentRawWriteIndex = (currentRawWriteIndex + 1) % rawLength

        // Check if we have enough samples for an LOD commit
        if windowStats[0].count >= lodRatio {
          commitLOD()
        }
      }

      rawWriteIndex.store(currentRawWriteIndex, ordering: .relaxed)

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
      let rawWIdx = rawWriteIndex.load(ordering: .relaxed)
      return LODSnapshotRef(bufferSlots[index], rawStorage: rawBandStorage, rawWriteIndex: rawWIdx)
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

    /// Flushes any partially-accumulated LOD window into the buffers.
    ///
    /// `process(_:)` only commits when it has seen a full `lodRatio` samples.
    /// For offline/file-based workflows (e.g. rendering a waveform for an exact
    /// time range), you typically want the final partial window to be included.
    ///
    /// This commits the current window if it contains at least one sample.
    public func finalize() {
      if windowStats.first?.count ?? 0 > 0 {
        commitLOD()
      }
    }

    // MARK: - Reset

    /// Resets all buffers and filter states.
    ///
    /// Call this when starting a new recording.
    public func reset() {
      // Reset filter states
      for i in filterStates.indices {
        filterStates[i].reset()
      }

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

      rawWriteIndex.store(0, ordering: .relaxed)
      // Zero out raw buffers
      for b in rawBandStorage.buffers {
        b.initialize(repeating: 0)
      }

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
    ) async throws(LODGenerationError) -> MultiBandLODSnapshot {
      let file: AVFAudio.AVAudioFile
      do {
        file = try AVFAudio.AVAudioFile(forReading: url)
      } catch {
        throw .audioFileOpenFailed(url: url, error: ErrorContext(error))
      }
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
        do {
          try file.read(into: buffer, frameCount: framesToRead)
        } catch {
          throw .audioFileReadFailed(url: url, error: ErrorContext(error))
        }

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

    /// Generate LOD data from specific segments of an audio file.
    ///
    /// Segments are concatenated in the order provided to form a trimmed snapshot.
    ///
    /// - Parameters:
    ///   - url: URL of the audio file to process.
    ///   - segments: Ordered time ranges (in seconds) to include.
    ///   - configuration: LOD configuration to use.
    /// - Returns: LOD snapshot representing only the provided segments.
    public static func generateFromFile(
      url: URL,
      segments: [ClosedRange<TimeInterval>],
      configuration: MultiBandLODConfiguration = .default
    ) async throws(LODGenerationError) -> MultiBandLODSnapshot {
      let file: AVFAudio.AVAudioFile
      do {
        file = try AVFAudio.AVAudioFile(forReading: url)
      } catch {
        throw .audioFileOpenFailed(url: url, error: ErrorContext(error))
      }
      let processingFormat = file.processingFormat
      let sampleRate = max(processingFormat.sampleRate, 1)
      let fileDuration = Double(file.length) / sampleRate

      let normalizedSegments: [ClosedRange<TimeInterval>] = segments.compactMap { range in
        let lower = max(0, min(range.lowerBound, range.upperBound))
        let upper = max(0, max(range.lowerBound, range.upperBound))
        let clampedLower = min(lower, fileDuration)
        let clampedUpper = min(max(clampedLower, upper), fileDuration)
        guard clampedUpper > clampedLower else { return nil }
        return clampedLower...clampedUpper
      }

      guard !normalizedSegments.isEmpty else {
        return .empty
      }

      let segmentFrames:
        [(start: AVFAudio.AVAudioFramePosition, end: AVFAudio.AVAudioFramePosition)]
      segmentFrames = normalizedSegments.map { range in
        let start = AVFAudio.AVAudioFramePosition(range.lowerBound * sampleRate)
        let end = AVFAudio.AVAudioFramePosition(range.upperBound * sampleRate)
        return (start: start, end: max(start, end))
      }

      let totalFrames = segmentFrames.reduce(0) { sum, frames in
        let count = max(AVFAudio.AVAudioFramePosition(0), frames.end - frames.start)
        return sum + max(0, Int(count))
      }

      guard totalFrames > 0 else {
        return .empty
      }

      let (paddedFrameCount, paddedOverflow) = totalFrames.addingReportingOverflow(
        max(configuration.lodRatio, 1)
      )
      let rawBufferLengthOverride = paddedOverflow ? totalFrames : paddedFrameCount
      let bufferSeconds = max(Int(ceil(Double(totalFrames) / sampleRate)), 1)
      let adjustedConfig = MultiBandLODConfiguration(
        bandCount: configuration.bandCount,
        lodRatio: configuration.lodRatio,
        bufferSeconds: bufferSeconds,
        sampleRate: Int(sampleRate),
        crossoverMode: configuration.crossoverMode,
        snapshotSwapInterval: configuration.snapshotSwapInterval,
        rawBufferLengthOverride: rawBufferLengthOverride
      )

      let processor = MultiBandLODProcessor(configuration: adjustedConfig)

      let bufferSize: AVFAudio.AVAudioFrameCount = 4096
      guard
        let buffer = AVFAudio.AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: bufferSize
        )
      else {
        throw LODGenerationError.bufferCreationFailed
      }

      for frames in segmentFrames {
        var framesRemaining = max(AVFAudio.AVAudioFramePosition(0), frames.end - frames.start)

        file.framePosition = frames.start

        while framesRemaining > 0 {
          let framesToRead = min(bufferSize, AVFAudio.AVAudioFrameCount(framesRemaining))
          do {
            try file.read(into: buffer, frameCount: framesToRead)
          } catch {
            throw .audioFileReadFailed(url: url, error: ErrorContext(error))
          }

          guard buffer.frameLength > 0 else { break }

          if let channels = buffer.floatChannelData {
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(processingFormat.channelCount)

            if channelCount == 1 {
              processor.process(buffer)
            } else {
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

          framesRemaining -= AVFAudio.AVAudioFramePosition(buffer.frameLength)
        }
      }

      if processor.windowStats.first?.count ?? 0 > 0 {
        processor.commitLOD()
      }

      return processor.snapshotLocking()
    }

    /// Errors that can occur during LOD generation.
    public enum LODGenerationError: AudioError, LocalizedError {
      case bufferCreationFailed
      case invalidAudioFormat
      case audioFileOpenFailed(url: URL, error: ErrorContext)
      case audioFileReadFailed(url: URL, error: ErrorContext)

      public var errorDescription: String? {
        switch self {
        case .bufferCreationFailed:
          return "Failed to create audio buffer for processing"
        case .invalidAudioFormat:
          return "Audio file has an unsupported format"
        case .audioFileOpenFailed(let url, let error):
          return "Failed to open audio file \(url.lastPathComponent): \(error)"
        case .audioFileReadFailed(let url, let error):
          return "Failed to read audio file \(url.lastPathComponent): \(error)"
        }
      }

      public var description: String {
        errorDescription ?? String(describing: self)
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
