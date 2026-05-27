// © GoodHatsLLC

#if canImport(UIKit) && !os(macOS)

  public import AVFAudio
  public import Observation
  import Tools
  public import UIKit

  @MainActor
  @Observable
  public final class OrientationObserver {
    public private(set) var orientation: UIDeviceOrientation
    public var stereoOrientation: AVAudioSession.StereoOrientation {
      switch orientation {
      case .unknown:
        return .portrait
      case .portrait:
        return .portrait
      case .portraitUpsideDown:
        return .portraitUpsideDown
      case .landscapeLeft:
        return .landscapeLeft
      case .landscapeRight:
        return .landscapeRight
      case .faceUp:
        return .portrait
      case .faceDown:
        return .portrait
      @unknown default:
        return .portrait
      }
    }

    init() {
      orientation = UIDevice.current.orientation
    }

    public func run() async {
      for await o in Self.stream() {
        orientation = o
      }
    }

    @MainActor
    private static func stream() -> AsyncSignalStream<UIDeviceOrientation> {
      let observerRunner = AsyncTaskRunner()
      let terminationRunner = AsyncTaskRunner()
      let signal = AsyncSignal<UIDeviceOrientation>(
        bufferingPolicy: .unbounded,
        terminationHandler: { _ in
          observerRunner.cancelAllNow()
          terminationRunner.run { @MainActor in
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
          }
        },
      )
      UIDevice.current.beginGeneratingDeviceOrientationNotifications()
      observerRunner.run { @MainActor in
        for await _ in NotificationCenter.default.notifications(
          named: UIDevice.orientationDidChangeNotification,
        ) {
          signal.yield(UIDevice.current.orientation)
        }
      }
      return signal.events()
    }
  }
#endif
