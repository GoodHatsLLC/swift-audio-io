import Atomics
import Foundation

/// A single-producer/single-consumer ring buffer with non-overwriting writes.
///
/// The producer writes full chunks or drops them when the buffer is full.
/// The consumer reads without locking and advances the read index after copying.
// SAFETY: SPSC invariants plus atomic indices guarantee race-free producer/consumer access.
@safe public final class SPSCRingBuffer<T>: @unchecked Sendable {
  private var buffer: UnsafeMutableBufferPointer<T>
  private let capacityMask: Int
  private var writeIndex: ManagedAtomic<Int>
  private var readIndex: ManagedAtomic<Int>
  #if DEBUG
    private let dropCount = ManagedAtomic<Int64>(0)
  #endif

  public init(capacity: Int) {
    let adjustedCapacity = Int.nextPowerOfTwo(max(capacity, 1))
    self.capacity = adjustedCapacity
    self.capacityMask = adjustedCapacity - 1

    let pointer = UnsafeMutablePointer<T>.allocate(capacity: self.capacity)
    unsafe self.buffer = unsafe UnsafeMutableBufferPointer(start: pointer, count: self.capacity)

    self.writeIndex = ManagedAtomic<Int>(0)
    self.readIndex = ManagedAtomic<Int>(0)
  }

  deinit {
    if unsafe buffer.baseAddress != nil {
      unsafe buffer.deallocate()
    }
  }

  /// The maximum space available in the ring buffer.
  public let capacity: Int

  public var availableToRead: Int {
    let currentWrite = writeIndex.load(ordering: .acquiring)
    let currentRead = readIndex.load(ordering: .acquiring)
    return currentWrite &- currentRead
  }

  public var availableToWrite: Int {
    capacity - availableToRead
  }

  /// Write elements from an unsafe buffer to the ring buffer.
  /// - Returns: The number of elements written (0 if dropped).
  @discardableResult
  public func write(_ data: UnsafeBufferPointer<T>) -> Int {
    let totalToWrite = min(data.count, capacity)
    guard totalToWrite > 0, let sourceBaseAddress = data.baseAddress else { return 0 }

    let available = availableToWrite
    guard totalToWrite <= available else {
      #if DEBUG
        dropCount.wrappingIncrement(by: Int64(totalToWrite), ordering: .relaxed)
      #endif
      return 0
    }

    let currentWrite = writeIndex.load(ordering: .acquiring)
    let writePos = currentWrite & capacityMask
    let remainingToEnd = capacity - writePos

    guard let bufferBase = unsafe buffer.baseAddress else { return 0 }

    if totalToWrite <= remainingToEnd {
      unsafe bufferBase.advanced(by: writePos)
        .update(from: sourceBaseAddress, count: totalToWrite)
    } else {
      let firstWrite = remainingToEnd
      unsafe bufferBase.advanced(by: writePos)
        .update(from: sourceBaseAddress, count: firstWrite)
      let remaining = totalToWrite - firstWrite
      unsafe bufferBase
        .update(from: sourceBaseAddress.advanced(by: firstWrite), count: remaining)
    }

    writeIndex.store(currentWrite &+ totalToWrite, ordering: .releasing)
    return totalToWrite
  }

  /// Read from the ring buffer into a provided unsafe mutable buffer.
  /// - Returns: The number of elements actually read.
  @discardableResult
  public func read(into destination: UnsafeMutableBufferPointer<T>) -> Int {
    guard let dest = destination.baseAddress else { return 0 }

    let currentRead = readIndex.load(ordering: .acquiring)
    let currentWrite = writeIndex.load(ordering: .acquiring)
    let available = currentWrite &- currentRead
    let toRead = Swift.min(destination.count, available)
    guard toRead > 0 else { return 0 }

    let readPos = currentRead & capacityMask
    let remainingToEnd = capacity - readPos

    guard let bufferBase = unsafe buffer.baseAddress else { return 0 }

    if toRead <= remainingToEnd {
      unsafe dest.update(from: bufferBase.advanced(by: readPos), count: toRead)
    } else {
      let firstRead = remainingToEnd
      unsafe dest.update(from: bufferBase.advanced(by: readPos), count: firstRead)
      let remaining = toRead - firstRead
      unsafe dest.advanced(by: firstRead)
        .update(from: bufferBase, count: remaining)
    }

    readIndex.store(currentRead &+ toRead, ordering: .releasing)
    return toRead
  }

  /// Discard all pending data. Safe to call from the consumer (reader) thread.
  public func clear() {
    let currentWrite = writeIndex.load(ordering: .acquiring)
    readIndex.store(currentWrite, ordering: .releasing)
  }

  #if DEBUG
    public var debugDropCount: Int64 {
      dropCount.load(ordering: .relaxed)
    }
  #endif
}

extension Int {
  fileprivate static func nextPowerOfTwo(_ value: Int) -> Int {
    var power = 1
    while power < value {
      power *= 2
    }
    return power
  }
}
