// © GoodHatsLLC

#if canImport(UIKit) && !os(macOS)

  public import AVFAudio
  import Combine
  public import Observation
  import SwiftUI
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

    private static func stream() -> AsyncSignalStream<UIDeviceOrientation> {
      let (stream, cont) = AsyncSignalStream.makeStream(of: UIDeviceOrientation.self)
      UIDevice.current.beginGeneratingDeviceOrientationNotifications()
      let cancellable = NotificationCenter.default
        .publisher(for: UIDevice.orientationDidChangeNotification)
        .map { _ in UIDevice.current.orientation }
        .sink { _ in
          cont.finish()
        } receiveValue: { value in
          cont.yield(value)
        }
      let c = Transferring(cancellable)
      let terminationTasks = AsyncTaskRunner()
      cont.onTermination = { _ in
        terminationTasks.run { [c, terminationTasks] in
          await MainActor.run {
            c.value.cancel()
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
          }
          _ = terminationTasks
        }
      }
      return stream
    }
  }
#endif
