// © GoodHatsLLC

import Atomics
import Darwin
public import Foundation

/// A cross-process single-producer / single-consumer ring buffer of `Float`
/// audio levels backed by a memory-mapped file.
///
/// Designed for live audio level publication from a recorder's host process
/// to a Live Activity widget extension. The producer (recorder) creates a
/// writer-mode instance; the consumer (widget) creates a reader-mode instance
/// over the same file path inside an App Group container.
///
/// Mirrors the structural pattern of ``SPSCRingBuffer`` — power-of-two
/// capacity with mask wrap, monotonic sequence-number indices with
/// `&+` / `&-` overflow-tolerant arithmetic, and `.acquiring` / `.releasing`
/// memory orderings — but stores the buffer in a process-shared mmap'd
/// region instead of a heap allocation.
///
/// ## Concurrency model
///
/// - **Writer**: a single thread. ``append(_:)`` is allocation-free,
///   lock-free, and safe to call from an audio render thread (one atomic
///   store, no syscalls on the hot path).
/// - **Reader**: a single thread. ``snapshot(into:)`` does one atomic load
///   followed by direct memory reads.
/// - **Cross-process correctness**: atomic operations target memory pages
///   shared by `mmap`. ARM64 `LDAR` / `STLR` (and the equivalent `Atomics`
///   release/acquire orderings) apply identically across the two virtual
///   address spaces because they ultimately operate on the same physical
///   page.
///
/// ## Tearing tolerance
///
/// The *index* is never torn (atomic 64-bit load/store). Sample data may be
/// observed mid-overwrite at the wrap-around boundary; the visual effect is
/// invisible at 60 Hz, so we do not pay for stronger guarantees.
// SAFETY: SPSC discipline + release/acquire on a hardware atomic in mmap'd shared memory; pointer state is set in init and torn down only in deinit.
@safe public final class LiveLevelRingBuffer: @unchecked Sendable {
  public enum Mode: Sendable {
    case writer
    case reader
  }

  public enum Error: Swift.Error, Equatable {
    case capacityNotPowerOfTwo(Int)
    case fileNotFound(URL)
    case openFailed(URL, errno: Int32)
    case truncateFailed(URL, errno: Int32)
    case mmapFailed(URL, errno: Int32)
    case headerCorrupt(magic: UInt32, version: UInt32, capacity: UInt32)
  }

  public struct SnapshotInfo: Sendable, Equatable {
    public let samplesRead: Int
    public let writeIndex: UInt64

    public init(samplesRead: Int, writeIndex: UInt64) {
      self.samplesRead = samplesRead
      self.writeIndex = writeIndex
    }
  }

  /// 'LVL1' — file format magic for the live level ring buffer.
  public static let fileMagic: UInt32 = 0x4C56_4C31
  /// Header layout version — bump on incompatible changes.
  public static let formatVersion: UInt32 = 1
  /// Header occupies the first 64 bytes; data follows immediately.
  public static let headerSize: Int = 64

  public let capacity: Int
  public let mode: Mode
  public let url: URL

  private let capacityMask: Int
  private let mappingSize: Int

  private let rawPointer: UnsafeMutableRawPointer
  private let writeIndexAtomic: UnsafeAtomic<UInt64>
  private let dataPointer: UnsafeMutablePointer<Float>

  public init(url: URL, capacity: Int, mode: Mode) throws {
    guard capacity > 0, (capacity & (capacity - 1)) == 0 else {
      throw Error.capacityNotPowerOfTwo(capacity)
    }
    self.capacity = capacity
    self.capacityMask = capacity - 1
    self.mode = mode
    self.url = url

    let dataBytes = capacity * MemoryLayout<Float>.stride
    let pageSize = Int(getpagesize())
    let total = Self.headerSize + dataBytes
    let aligned = (total + pageSize - 1) & ~(pageSize - 1)
    self.mappingSize = aligned

    // Open the file. Writer creates it if missing.
    let path = url.path(percentEncoded: false)
    let openFlags: Int32 =
      (mode == .writer)
      ? (O_RDWR | O_CREAT | O_NOFOLLOW)
      : (O_RDONLY | O_NOFOLLOW)
    let fd = path.withCString { cstr in
      unsafe Darwin.open(cstr, openFlags, mode_t(0o600))
    }
    guard fd >= 0 else {
      let err = errno
      if mode == .reader, err == ENOENT {
        throw Error.fileNotFound(url)
      }
      throw Error.openFailed(url, errno: err)
    }
    defer { _ = Darwin.close(fd) }

    // Size the file (writer only).
    if mode == .writer {
      if Darwin.ftruncate(fd, off_t(aligned)) != 0 {
        let err = errno
        throw Error.truncateFailed(url, errno: err)
      }
    }

    // Memory-map the file shared with the other process.
    let prot: Int32 =
      (mode == .writer)
      ? (PROT_READ | PROT_WRITE)
      : PROT_READ
    let mapped: UnsafeMutableRawPointer! = unsafe Darwin.mmap(
      nil, aligned, prot, MAP_SHARED, fd, 0,
    )
    let mappedBits = Int(bitPattern: mapped)
    if mappedBits == -1 {
      let err = errno
      throw Error.mmapFailed(url, errno: err)
    }
    let raw: UnsafeMutableRawPointer = unsafe mapped

    // Header layout: 4 × UInt32 then UInt64 atomic write index, then padding,
    // then the data slab starts at `headerSize`.
    let headerWords = unsafe raw.assumingMemoryBound(to: UInt32.self)
    let writeIndexPtr = unsafe raw.advanced(by: 16)
      .assumingMemoryBound(to: UInt64.AtomicRepresentation.self)
    let dataPtr = unsafe raw.advanced(by: Self.headerSize)
      .assumingMemoryBound(to: Float.self)
    let writeIndexAtomic = unsafe UnsafeAtomic<UInt64>(at: writeIndexPtr)

    switch mode {
    case .writer:
      // Writer always rewrites the header and resets the index — every
      // writer session starts with a clean monotonic count.
      unsafe headerWords[0] = Self.fileMagic
      unsafe headerWords[1] = Self.formatVersion
      unsafe headerWords[2] = UInt32(capacity)
      unsafe headerWords[3] = 0
      writeIndexAtomic.store(0, ordering: .releasing)
    case .reader:
      let magic = unsafe headerWords[0]
      let version = unsafe headerWords[1]
      let storedCapacity = unsafe headerWords[2]
      if magic != Self.fileMagic
        || version != Self.formatVersion
        || storedCapacity != UInt32(capacity)
      {
        unsafe _ = Darwin.munmap(raw, aligned)
        throw Error.headerCorrupt(
          magic: magic, version: version, capacity: storedCapacity)
      }
    }

    unsafe self.rawPointer = raw
    self.writeIndexAtomic = writeIndexAtomic
    unsafe self.dataPointer = dataPtr
  }

  deinit {
    unsafe _ = Darwin.munmap(rawPointer, mappingSize)
  }

  // MARK: - Writer side (audio-thread safe)

  /// Append a single sample. **Writer-only.** Lock-free; safe to call from
  /// an audio render thread.
  public func append(_ sample: Float) {
    let prev = writeIndexAtomic.load(ordering: .relaxed)
    let pos = Int(prev & UInt64(capacityMask))
    unsafe dataPointer[pos] = sample
    writeIndexAtomic.store(prev &+ 1, ordering: .releasing)
  }

  // MARK: - Reader side

  /// The current monotonic write index — total samples ever written. Useful
  /// as a heartbeat or staleness check from the reader's display loop.
  public var writeIndex: UInt64 {
    writeIndexAtomic.load(ordering: .acquiring)
  }

  /// Snapshot the most-recent samples into `destination` in chronological
  /// order (oldest first, newest last).
  ///
  /// Returns the number of samples written and the current write index.
  /// If fewer samples have been produced than `destination.count`, the tail
  /// of the destination is left untouched.
  @discardableResult
  public func snapshot(into destination: inout [Float]) -> SnapshotInfo {
    let cur = writeIndexAtomic.load(ordering: .acquiring)
    let want = destination.count
    let available = Int(Swift.min(cur, UInt64(capacity)))
    let toRead = Swift.min(want, available)
    guard toRead > 0 else {
      return SnapshotInfo(samplesRead: 0, writeIndex: cur)
    }
    let firstSampleIndex = cur &- UInt64(toRead)
    destination.withUnsafeMutableBufferPointer { dest in
      for i in 0..<toRead {
        let srcIndex = Int((firstSampleIndex &+ UInt64(i)) & UInt64(capacityMask))
        unsafe dest[i] = unsafe dataPointer[srcIndex]
      }
    }
    return SnapshotInfo(samplesRead: toRead, writeIndex: cur)
  }
}
