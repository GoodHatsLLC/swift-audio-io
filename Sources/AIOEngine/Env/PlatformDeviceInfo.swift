import AVFAudio
import Foundation

/// Platform-agnostic stereo orientation
public enum StereoOrientation: Sendable {
  case portrait
  case portraitUpsideDown
  case landscapeLeft
  case landscapeRight

  #if !os(macOS)
  var avAudioSessionOrientation: AVAudioSession.StereoOrientation {
    switch self {
    case .portrait: .portrait
    case .portraitUpsideDown: .portraitUpsideDown
    case .landscapeLeft: .landscapeLeft
    case .landscapeRight: .landscapeRight
    }
  }

  init(_ orientation: AVAudioSession.StereoOrientation) {
    switch orientation {
    case .portrait: self = .portrait
    case .portraitUpsideDown: self = .portraitUpsideDown
    case .landscapeLeft: self = .landscapeLeft
    case .landscapeRight: self = .landscapeRight
    case .none: self = .portrait
    @unknown default: self = .portrait
    }
  }
  #endif
}

/// Platform-agnostic device information provider for audio session configuration
public protocol PlatformDeviceInfo: Sendable {
  /// Current stereo orientation for audio capture
  var currentOrientation: StereoOrientation { get async }

  /// Async stream of orientation changes
  func orientationChanges() -> AsyncStream<StereoOrientation>
}

// MARK: - iOS Implementation

#if canImport(UIKit) && !os(macOS)
  import UIKit

  /// iOS implementation of device info that tracks physical device orientation
  public actor IOSDeviceInfo: PlatformDeviceInfo {
    private var _currentOrientation: StereoOrientation = .portrait

      @MainActor
    public init() {
      UIDevice.current.beginGeneratingDeviceOrientationNotifications()
      _currentOrientation = Self.mapOrientation(UIDevice.current.orientation) ?? .portrait
    }

    public var currentOrientation: StereoOrientation {
      _currentOrientation
    }

    public nonisolated func orientationChanges() -> AsyncStream<StereoOrientation> {
      AsyncStream { continuation in
        let task = Task { @MainActor in
          let notifications = NotificationCenter.default.notifications(
            named: UIDevice.orientationDidChangeNotification)

          for await notification in notifications {
            let device = (notification.object as? UIDevice) ?? UIDevice.current
            if let mapped = Self.mapOrientation(device.orientation) {
              await self.update(orientation: mapped)
              continuation.yield(mapped)
            }
          }
        }

        continuation.onTermination = { _ in
          task.cancel()
        }
      }
    }

    private func update(orientation: StereoOrientation) {
      _currentOrientation = orientation
    }

    private static func mapOrientation(
      _ orientation: UIDeviceOrientation
    ) -> StereoOrientation? {
      switch orientation {
      case .portrait: .portrait
      case .portraitUpsideDown: .portraitUpsideDown
      case .landscapeLeft: .landscapeLeft
      case .landscapeRight: .landscapeRight
      case .faceUp, .faceDown, .unknown: nil
      @unknown default: nil
      }
    }
  }
#endif

// MARK: - macOS Implementation

#if os(macOS)
  /// macOS implementation of device info
  ///
  /// macOS devices don't have physical orientation changes, so this returns
  /// a fixed portrait orientation for consistency with the audio engine.
  public actor MacOSDeviceInfo: PlatformDeviceInfo {
    public init() {}

    public var currentOrientation: StereoOrientation {
      .portrait
    }

    public nonisolated func orientationChanges() -> AsyncStream<StereoOrientation> {
      // Return empty stream - macOS doesn't change orientation
      AsyncStream { continuation in
        continuation.finish()
      }
    }
  }
#endif

// MARK: - Factory

enum PlatformDevice {
    @MainActor
  /// Creates the appropriate device info implementation for the current platform
  public static func create() -> any PlatformDeviceInfo {
    #if canImport(UIKit) && !os(macOS)
      return IOSDeviceInfo()
    #elseif os(macOS)
      return MacOSDeviceInfo()
    #else
      fatalError("Unsupported platform")
    #endif
  }
}
