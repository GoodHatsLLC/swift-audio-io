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

}
