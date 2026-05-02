// © GoodHatsLLC

import Testing

struct AIOQuickstartTests {
  @Test
  @MainActor
  func `README quickstart type-checks against AIOEngine`() {
    let quickstart: @MainActor () async throws -> Void = aioQuickstart
    _ = quickstart
  }
}
