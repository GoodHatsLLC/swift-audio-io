// © GoodHatsLLC

import Foundation
import os

enum SystemLog {
  static func make(
    subsystem: String = defaultSubsystem,
    category: String = #fileID,
  ) -> Logger {
    Logger(
      subsystem: subsystem,
      category: normalizedCategory(from: category),
    )
  }

  private static let defaultSubsystem: String = {
    if let subsystem = Bundle.main.bundleIdentifier, !subsystem.isEmpty {
      return subsystem
    }
    return "AudioSignals"
  }()

  private static func normalizedCategory(from fileID: String) -> String {
    let filename = fileID.split(separator: "/").last.map(String.init) ?? fileID
    return filename.replacingOccurrences(of: ".swift", with: "")
  }
}
