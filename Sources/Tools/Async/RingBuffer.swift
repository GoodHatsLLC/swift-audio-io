import Atomics
import Foundation

/// A bounded ring buffer safe for concurrent readers and writers.
///
/// Thread-safety is enforced with a platform-neutral `NSLock` around index updates while
/// keeping reads and writes lock-protected to maintain consistency. The underlying
/// indices are atomically managed to minimize contention; @unchecked Sendable is used
/// because correctness relies on the internal locking discipline.
public final class RingBuffer<T>: @unchecked Sendable {
  private var buffer: UnsafeMutableBufferPointer<T>
  private let capacityMask: Int
  private var writeIndex: ManagedAtomic<Int>
  private var readIndex: ManagedAtomic<Int>
  private let lock = NSLock()

  public init(capacity: Int) {
    let adjustedCapacity = Int.nextPowerOfTwo(capacity)
    self.capacity = adjustedCapacity
    self.capacityMask = adjustedCapacity - 1

    let pointer = UnsafeMutablePointer<T>.allocate(capacity: self.capacity)
    self.buffer = UnsafeMutableBufferPointer(start: pointer, count: self.capacity)

    self.writeIndex = ManagedAtomic<Int>(0)
    self.readIndex = ManagedAtomic<Int>(0)

  }

  deinit {
    // Only deallocate if properly initialized
    if buffer.baseAddress != nil {
      buffer.deallocate()
    }
  }

  /// The maximum space available in the ring buffer
  public let capacity: Int

  /// Write elements to the ring buffer, always succeeding by overwriting if necessary
  /// - Returns: The number of elements actually written
  @discardableResult
  public func write(_ data: [T]) -> Int {
    let totalToWrite = min(data.count, capacity)
    guard totalToWrite > 0 else { return 0 }

    return data.withUnsafeBufferPointer { bufferPointer in
      write(bufferPointer)
    }
  }

  /// Write elements from an unsafe buffer to the ring buffer, overwriting if necessary.
  /// This method is optimized to avoid intermediate allocations.
  /// - Returns: The number of elements actually written.
  @discardableResult
  public func write(_ data: UnsafeBufferPointer<T>) -> Int {
    let totalToWrite = min(data.count, capacity)
    guard totalToWrite > 0, let sourceBaseAddress = data.baseAddress else { return 0 }

    lock.lock()
    defer { lock.unlock() }

    let currentWrite = writeIndex.load(ordering: .acquiring)
    let currentRead = readIndex.load(ordering: .acquiring)

    let newWrite = currentWrite &+ totalToWrite
    let occupied = currentWrite &- currentRead

    // Calculate new read index if we need to overwrite
    let newRead: Int
    if occupied + totalToWrite > capacity {
      // We need to overwrite, advance read index
      let overwrittenCount = (occupied + totalToWrite) - capacity
      newRead = currentRead &+ overwrittenCount
    } else {
      newRead = currentRead
    }

    // Update indices atomically
    writeIndex.store(newWrite, ordering: .releasing)
    if newRead != currentRead {
      readIndex.store(newRead, ordering: .releasing)
    }

    // Write the data
    let writePos = currentWrite & capacityMask
    let remainingToEnd = capacity - writePos

    guard let bufferBase = buffer.baseAddress else { return 0 }

    if totalToWrite <= remainingToEnd {
      // Single continuous write
      bufferBase.advanced(by: writePos)
        .update(from: sourceBaseAddress, count: totalToWrite)
    } else {
      // Split write
      let firstWrite = remainingToEnd
      bufferBase.advanced(by: writePos)
        .update(from: sourceBaseAddress, count: firstWrite)

      // Write remaining at start of buffer
      let remaining = totalToWrite - firstWrite
      bufferBase
        .update(from: sourceBaseAddress.advanced(by: firstWrite), count: remaining)
    }

    return totalToWrite
  }

  /// Read from the ring buffer
  /// - Returns: Array of read elements
  public func read(_ count: Int) -> [T] {
    guard count > 0 else { return [] }

    // Get available data count first
    let availableCount = self.count
    let toRead = min(count, availableCount)
    guard toRead > 0 else { return [] }

    // Create temporary buffer to read into
    let tempBuffer = UnsafeMutableBufferPointer<T>.allocate(capacity: toRead)
    defer { tempBuffer.deallocate() }

    let actualRead = read(into: tempBuffer)
    guard actualRead > 0 else { return [] }

    // Convert to array safely
    var result: [T] = []
    result.reserveCapacity(actualRead)

    let bufferPointer = UnsafeBufferPointer(start: tempBuffer.baseAddress, count: actualRead)
    for element in bufferPointer {
      result.append(element)
    }

    return result
  }

  /// Read from the ring buffer into a provided unsafe mutable buffer.
  /// This method is optimized to avoid allocations by writing into a pre-allocated buffer.
  /// - Parameter destination: The buffer to read data into.
  /// - Returns: The number of elements actually read.
  @discardableResult
  public func read(into destination: UnsafeMutableBufferPointer<T>) -> Int {
    guard let dest = destination.baseAddress else { return 0 }
    lock.lock()
    defer { lock.unlock() }

    let currentRead = readIndex.load(ordering: .acquiring)
    let currentWrite = writeIndex.load(ordering: .acquiring)
    let available = currentWrite &- currentRead
    let toRead = Swift.min(destination.count, available)
    guard toRead > 0 else { return 0 }

    let readPos = currentRead & capacityMask
    let remainingToEnd = capacity - readPos

    guard let bufferBase = buffer.baseAddress else { return 0 }

    if toRead <= remainingToEnd {
      // Single continuous read
      dest.update(from: bufferBase.advanced(by: readPos), count: toRead)
    } else {
      // Split read
      let firstRead = remainingToEnd
      dest.update(from: bufferBase.advanced(by: readPos), count: firstRead)
      let remaining = toRead - firstRead
      dest.advanced(by: firstRead)
        .update(
          from: bufferBase,
          count: remaining
        )
    }

    // Update read index after successful read
    let newRead = currentRead &+ toRead
    readIndex.store(newRead, ordering: .releasing)

    return toRead
  }

  /// The number of data elements in the ring buffer
  public var count: Int {
    lock.lock()
    defer { lock.unlock() }

    let currentWrite = writeIndex.load(ordering: .acquiring)
    let currentRead = readIndex.load(ordering: .acquiring)
    return currentWrite &- currentRead
  }

  /// Clear the ring buffer's indices without resetting values
  public func clearIndices() {
    lock.lock()
    defer { lock.unlock() }

    writeIndex.store(0, ordering: .releasing)
    readIndex.store(0, ordering: .releasing)
  }
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
