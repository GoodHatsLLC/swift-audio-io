// © GoodHatsLLC

import Foundation
import Testing

@testable import Tools

@Suite("LiveLevelRingBuffer")
struct LiveLevelRingBufferTests {

  // MARK: - Helpers

  /// Make a fresh temp URL for a ring buffer file. The file is *not* created;
  /// the writer mode will create it on init.
  private func makeTempURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiveLevelRingBufferTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("levels.ring")
  }

  // MARK: - Construction

  @Test("init rejects non-power-of-two capacity")
  func capacityValidation() throws {
    let url = makeTempURL()
    #expect(throws: LiveLevelRingBuffer.Error.capacityNotPowerOfTwo(15)) {
      _ = try LiveLevelRingBuffer(url: url, capacity: 15, mode: .writer)
    }
  }

  @Test("reader fails when file does not exist")
  func readerOnMissingFile() throws {
    let url = makeTempURL()
    #expect(throws: LiveLevelRingBuffer.Error.self) {
      _ = try LiveLevelRingBuffer(url: url, capacity: 16, mode: .reader)
    }
  }

  @Test("reader rejects header with wrong capacity")
  func readerRejectsCapacityMismatch() throws {
    let url = makeTempURL()
    _ = try LiveLevelRingBuffer(url: url, capacity: 16, mode: .writer)
    #expect(throws: LiveLevelRingBuffer.Error.self) {
      _ = try LiveLevelRingBuffer(url: url, capacity: 32, mode: .reader)
    }
  }

  // MARK: - Writer / reader round-trip

  @Test("writer + reader round-trip on freshly created file")
  func roundTrip() throws {
    let url = makeTempURL()
    let writer = try LiveLevelRingBuffer(url: url, capacity: 16, mode: .writer)
    for i in 0..<10 {
      writer.append(Float(i))
    }

    let reader = try LiveLevelRingBuffer(url: url, capacity: 16, mode: .reader)
    var dest = [Float](repeating: -1, count: 16)
    let info = reader.snapshot(into: &dest)

    #expect(info.writeIndex == 10)
    #expect(info.samplesRead == 10)
    #expect(Array(dest.prefix(10)) == (0..<10).map(Float.init))
    // Tail is left untouched (still the sentinel -1).
    #expect(dest[10] == -1)
  }

  @Test("snapshot returns most-recent N samples after wrap")
  func wrapAround() throws {
    let url = makeTempURL()
    let capacity = 8
    let writer = try LiveLevelRingBuffer(url: url, capacity: capacity, mode: .writer)
    let reader = try LiveLevelRingBuffer(url: url, capacity: capacity, mode: .reader)

    // Write 20 samples into an 8-slot buffer; only the last 8 survive.
    for i in 0..<20 {
      writer.append(Float(i))
    }
    var dest = [Float](repeating: -1, count: capacity)
    let info = reader.snapshot(into: &dest)
    #expect(info.writeIndex == 20)
    #expect(info.samplesRead == capacity)
    // Most-recent 8 samples: 12..<20, in chronological order.
    #expect(dest == (12..<20).map(Float.init))
  }

  @Test("snapshot before any write yields zero samples")
  func emptySnapshot() throws {
    let url = makeTempURL()
    _ = try LiveLevelRingBuffer(url: url, capacity: 16, mode: .writer)
    let reader = try LiveLevelRingBuffer(url: url, capacity: 16, mode: .reader)
    var dest = [Float](repeating: -1, count: 4)
    let info = reader.snapshot(into: &dest)
    #expect(info.writeIndex == 0)
    #expect(info.samplesRead == 0)
    #expect(dest == [-1, -1, -1, -1])
  }

  @Test("snapshot smaller than buffer returns most-recent slice")
  func partialSnapshot() throws {
    let url = makeTempURL()
    let writer = try LiveLevelRingBuffer(url: url, capacity: 16, mode: .writer)
    let reader = try LiveLevelRingBuffer(url: url, capacity: 16, mode: .reader)
    for i in 0..<10 {
      writer.append(Float(i))
    }
    var dest = [Float](repeating: -1, count: 4)
    let info = reader.snapshot(into: &dest)
    #expect(info.writeIndex == 10)
    #expect(info.samplesRead == 4)
    // Most-recent 4 samples: 6, 7, 8, 9.
    #expect(dest == [6, 7, 8, 9])
  }

  // MARK: - Persistence across writer sessions

  @Test("writer reset clears prior session data")
  func writerResetsIndex() throws {
    let url = makeTempURL()
    do {
      let writer = try LiveLevelRingBuffer(url: url, capacity: 16, mode: .writer)
      for i in 0..<5 {
        writer.append(Float(i))
      }
    }
    // Re-open as writer — index should reset to 0.
    let writer2 = try LiveLevelRingBuffer(url: url, capacity: 16, mode: .writer)
    #expect(writer2.writeIndex == 0)
    let reader = try LiveLevelRingBuffer(url: url, capacity: 16, mode: .reader)
    #expect(reader.writeIndex == 0)
  }

  // MARK: - Concurrent writer + reader

  @Test("concurrent writer and reader observe monotonic indices")
  func concurrentReadWrite() async throws {
    let url = makeTempURL()
    let capacity = 64
    let writer = try LiveLevelRingBuffer(url: url, capacity: capacity, mode: .writer)
    let reader = try LiveLevelRingBuffer(url: url, capacity: capacity, mode: .reader)

    let totalSamples = 5_000

    let writerFinished = AsyncContinuation<Void>()
    let firstWrite = AsyncContinuation<Void>()
    let readerStarted = AsyncContinuation<Void>()
    let writerTask = ActorOwnedWork(priority: .userInitiated) {
      for i in 0..<totalSamples {
        writer.append(Float(i))
        if i == 0 {
          try? firstWrite.yield()
          await readerStarted()
        }
      }
      try? writerFinished.yield()
    }

    await firstWrite()
    let readerTask = ActorOwnedWork(priority: .userInitiated) {
      try? readerStarted.yield()
      var lastIndex: UInt64 = 0
      var snapshots = 0
      var dest = [Float](repeating: 0, count: 16)
      while lastIndex < UInt64(totalSamples) {
        let info = reader.snapshot(into: &dest)
        // Monotonicity is required even under contention.
        #expect(info.writeIndex >= lastIndex)
        lastIndex = info.writeIndex
        snapshots += 1
        if snapshots > 1_000_000 { break }  // safety net
      }
      return lastIndex
    }

    await writerFinished()
    await writerTask.value
    let final = await readerTask.value
    #expect(final == UInt64(totalSamples))
  }
}
