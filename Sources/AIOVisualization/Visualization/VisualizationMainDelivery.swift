// © GoodHatsLLC

import Foundation

enum VisualizationMainDelivery {
  static func async(_ operation: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        operation()
      }
    }
  }
}
