// © GoodHatsLLC

import Testing

@testable import Tools

struct MiscTests {
  @Test
  func `duration seconds converts`() {
    let duration = Duration.seconds(3)
    #expect((duration.seconds - 3).magnitude < 0.000_001)
  }

  @Test
  func `synchronized updates value`() {
    let synchronized = Synchronized([1, 2, 3])
    synchronized { value in
      value.append(4)
    }
    #expect(synchronized.withLock(\.count) == 4)
  }
}
