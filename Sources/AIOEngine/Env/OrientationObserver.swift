//
//  OrientationObserver.swift
//  AIO
//
//  Created by adamz on 2025-08-03.
//

import Tools
import AVFAudio
import Combine
#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(UIKit) && !os(macOS)
import UIKit

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

  private var cancellable: AnyCancellable?

  init() {
    self.orientation = UIDevice.current.orientation
  }

  public func run() async {
    for await o in Self.stream() {
      self.orientation = o
    }
  }

  private static func stream() -> AsyncStream<UIDeviceOrientation> {
    let (stream, cont) = AsyncStream.makeStream(of: UIDeviceOrientation.self)
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
    cont.onTermination = { _ in
      Task.detached { @MainActor in
        c.value.cancel()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
      }
    }
    return stream
  }
}
#endif
