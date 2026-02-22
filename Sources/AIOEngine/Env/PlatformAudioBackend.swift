public import Foundation

/// Internal platform audio backend contract used to decouple call sites from platform-only APIs.
protocol PlatformAudioBackend: Sendable {
  var platformName: String { get }
  func routeChanges() -> AsyncStream<String>
  func availableInputNames() async -> [String]
}

enum PlatformAudioBackendFactory {
  static func makeDefault() -> any PlatformAudioBackend {
    #if os(iOS)
      return IOSPlatformAudioBackend()
    #elseif os(macOS)
      return MacOSPlatformAudioBackend()
    #else
      return UnsupportedPlatformAudioBackend()
    #endif
  }
}

#if os(iOS)
  import AVFoundation

  struct IOSPlatformAudioBackend: PlatformAudioBackend {
    let platformName: String = "iOS"

    func routeChanges() -> AsyncStream<String> {
      AsyncStream { continuation in
        let task = Task {
          let notifications = NotificationCenter.default.notifications(
            named: AVAudioSession.routeChangeNotification
          )
          for await _ in notifications {
            continuation.yield("routeChanged")
          }
        }
        continuation.onTermination = { _ in
          task.cancel()
        }
      }
    }

    func availableInputNames() async -> [String] {
      (AVAudioSession.sharedInstance().availableInputs ?? []).map(\.portName)
    }
  }
#elseif os(macOS)
  struct MacOSPlatformAudioBackend: PlatformAudioBackend {
    let platformName: String = "macOS"

    func routeChanges() -> AsyncStream<String> {
      AsyncStream { continuation in
        continuation.finish()
      }
    }

    func availableInputNames() async -> [String] {
      []
    }
  }
#else
  struct UnsupportedPlatformAudioBackend: PlatformAudioBackend {
    let platformName: String = "unsupported"

    func routeChanges() -> AsyncStream<String> {
      AsyncStream { continuation in
        continuation.finish()
      }
    }

    func availableInputNames() async -> [String] {
      []
    }
  }
#endif
