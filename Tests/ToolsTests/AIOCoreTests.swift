import Testing

@testable import Tools

@Suite
struct ToolsTests {
  @Test
  func durationSecondsConverts() {
    let duration = Duration.seconds(3)
    #expect((duration.seconds - 3).magnitude < 0.000_001)
  }

  @Test
  func synchronizedUpdatesValue() {
    let synchronized = Synchronized([1, 2, 3])
    synchronized { value in
      value.append(4)
    }
    #expect(synchronized.withLock(\.count) == 4)
  }

  @Test
  func ringBufferEnqueuesAndDequeues() {
    let ringBuffer = RingBuffer<Int>(capacity: 3)
    ringBuffer.write([1, 2])
    #expect(ringBuffer.count == 2)

    let consumed = ringBuffer.read(2)
    #expect(consumed == [1, 2])
    #expect(ringBuffer.count == 0)
  }
}
