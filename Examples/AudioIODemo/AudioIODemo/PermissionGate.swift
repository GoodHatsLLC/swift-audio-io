// Microphone permission across iOS and macOS.
//
// iOS uses AVAudioApplication.requestRecordPermission.
// macOS uses AVCaptureDevice.requestAccess(for: .audio).
//
// Both platforms also require an Info.plist NSMicrophoneUsageDescription key —
// see Info.plist in this directory.

import AVFoundation
import Foundation

enum MicrophonePermission: Sendable {
  case unknown
  case requesting
  case granted
  case denied

  static func current() -> MicrophonePermission {
    #if os(iOS)
      switch AVAudioApplication.shared.recordPermission {
      case .undetermined: return .unknown
      case .denied: return .denied
      case .granted: return .granted
      @unknown default: return .unknown
      }
    #elseif os(macOS)
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .notDetermined: return .unknown
      case .restricted, .denied: return .denied
      case .authorized: return .granted
      @unknown default: return .unknown
      }
    #else
      return .unknown
    #endif
  }

  static func request() async -> MicrophonePermission {
    #if os(iOS)
      let granted = await AVAudioApplication.requestRecordPermission()
      return granted ? .granted : .denied
    #elseif os(macOS)
      let granted = await AVCaptureDevice.requestAccess(for: .audio)
      return granted ? .granted : .denied
    #else
      return .denied
    #endif
  }
}
