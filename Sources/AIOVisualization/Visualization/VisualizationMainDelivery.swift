// © GoodHatsLLC

import Foundation
import Tools

enum VisualizationMainDelivery {
  static func async(_ operation: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        operation()
      }
    }
  }

  #if DEBUG
    static func drainForTesting() async {
      let drained = AsyncContinuation<Void>()
      async {
        try? drained.yield()
      }
      await drained()
    }
  #endif
}
