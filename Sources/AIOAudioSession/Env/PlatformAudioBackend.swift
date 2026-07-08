// © GoodHatsLLC

internal import Foundation
import Tools

/// Platform-neutral model of a discoverable audio input endpoint.
struct PlatformAudioInputDescriptor: Hashable {
  let id: String
  let name: String
  let type: AudioInput.InputType
  let channelCount: Int
  let isDefault: Bool

  init(
    id: String,
    name: String,
    type: AudioInput.InputType = .unknown,
    channelCount: Int,
    isDefault: Bool,
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.channelCount = channelCount
    self.isDefault = isDefault
  }
}

enum PlatformAudioRouteEvent: Hashable {
  case changed
}

/// Internal platform audio backend contract used to decouple call sites from platform-only APIs.
protocol PlatformAudioBackend: Sendable {
  var platformName: String { get }
  func routeChanges() -> AsyncSignalStream<PlatformAudioRouteEvent>
  // `@concurrent`: enumerating inputs is synchronous mediaserverd/CoreAudio-HAL
  // IPC. Without it, under this package's `NonisolatedNonsendingByDefault`
  // (SE-0461), the call would inherit the @MainActor caller and run the HAL IPC
  // on the main actor. Conformances must match.
  @concurrent func availableInputs() async -> [PlatformAudioInputDescriptor]
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
  import AIOSupport
  import AVFoundation

  struct IOSPlatformAudioBackend: PlatformAudioBackend {
    let platformName: String = "iOS"

    func routeChanges() -> AsyncSignalStream<PlatformAudioRouteEvent> {
      let routeRunner = AsyncTaskRunner()
      let availableInputsRunner: AsyncTaskRunner? =
        if #available(iOS 26.0, *) {
          AsyncTaskRunner()
        } else {
          nil
        }
      let signal = AsyncSignal<PlatformAudioRouteEvent>(
        bufferingPolicy: .unbounded,
        terminationHandler: { _ in
          routeRunner.cancelAllNow()
          availableInputsRunner?.cancelAllNow()
        },
      )
      routeRunner.run {
        let routeNotifications = NotificationCenter.default.notifications(
          named: AVAudioSession.routeChangeNotification,
        )
        for await _ in routeNotifications {
          signal.yield(.changed)
        }
      }
      if let availableInputsRunner {
        availableInputsRunner.run {
          let inputNotifications = NotificationCenter.default.notifications(
            named: AVAudioSession.availableInputsChangeNotification,
          )
          for await _ in inputNotifications {
            signal.yield(.changed)
          }
        }
      }
      return signal.events()
    }

    @concurrent func availableInputs() async -> [PlatformAudioInputDescriptor] {
      await AudioSessionAccess.async {
        let session = AVAudioSession.sharedInstance()
        let defaultInputID = session.currentRoute.inputs.first?.uid
        return (session.availableInputs ?? []).map { input in
          PlatformAudioInputDescriptor(
            id: input.uid,
            name: input.portName,
            type: AudioInput.InputType(input.portType),
            channelCount: max(input.channels?.count ?? 0, 1),
            isDefault: input.uid == defaultInputID,
          )
        }
        .sorted { lhs, rhs in
          lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
      }
    }
  }

#elseif os(macOS)
  import CoreAudio

  struct MacOSPlatformAudioBackend: PlatformAudioBackend {
    let platformName: String = "macOS"

    func routeChanges() -> AsyncSignalStream<PlatformAudioRouteEvent> {
      let runner = AsyncTaskRunner()
      let signal = AsyncSignal<PlatformAudioRouteEvent>(
        bufferingPolicy: .unbounded,
        terminationHandler: { _ in
          runner.cancelAllNow()
        },
      )
      runner.run {
        let sleeper = TaskSleeper()
        var previousSignature = routeSignature()
        while !Task.isCancelled {
          try? await sleeper.sleep(for: .milliseconds(750))
          let nextSignature = routeSignature()
          if nextSignature != previousSignature {
            previousSignature = nextSignature
            signal.yield(.changed)
          }
        }
        signal.finish()
      }
      return signal.events()
    }

    @concurrent func availableInputs() async -> [PlatformAudioInputDescriptor] {
      let defaultInputID = defaultInputDeviceUID()
      return audioInputDevices().map { input in
        PlatformAudioInputDescriptor(
          id: input.uid,
          name: input.name,
          type: input.type,
          channelCount: input.channelCount,
          isDefault: input.uid == defaultInputID,
        )
      }
      .sorted { lhs, rhs in
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
    }

    private struct CoreAudioInput {
      let uid: String
      let name: String
      let type: AudioInput.InputType
      let channelCount: Int
    }

    private struct RouteSignature: Hashable {
      let defaultInputID: String?
      let inputIDs: [String]
    }

    private func routeSignature() -> RouteSignature {
      let inputs = audioInputDevices().map(\.uid).sorted()
      return RouteSignature(
        defaultInputID: defaultInputDeviceUID(),
        inputIDs: inputs,
      )
    }

    private func audioInputDevices() -> [CoreAudioInput] {
      deviceIDs().compactMap { deviceID in
        let channels = inputChannelCount(deviceID: deviceID)
        guard channels > 0 else { return nil }
        guard
          let uid = stringProperty(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
          )
        else { return nil }
        let name =
          stringProperty(objectID: deviceID, selector: kAudioObjectPropertyName)
          ?? "Audio Input \(uid)"
        return CoreAudioInput(
          uid: uid,
          name: name,
          type: AudioInput.InputType(
            coreAudioTransportType: transportType(deviceID: deviceID),
          ),
          channelCount: channels,
        )
      }
    }

    private func transportType(deviceID: AudioDeviceID) -> UInt32 {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
      )
      var value: UInt32 = 0
      var dataSize = UInt32(MemoryLayout<UInt32>.size)
      let status = unsafe AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &dataSize,
        &value,
      )
      guard status == noErr else { return 0 }
      return value
    }

    private func defaultInputDeviceUID() -> String? {
      let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
      )
      var deviceID = AudioDeviceID(0)
      var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
      let status = unsafe AudioObjectGetPropertyData(
        systemObjectID,
        &address,
        0,
        nil,
        &dataSize,
        &deviceID,
      )
      guard status == noErr else { return nil }
      return stringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private func deviceIDs() -> [AudioDeviceID] {
      let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
      )
      var dataSize: UInt32 = 0
      let sizeStatus = unsafe AudioObjectGetPropertyDataSize(
        systemObjectID,
        &address,
        0,
        nil,
        &dataSize,
      )
      guard sizeStatus == noErr, dataSize > 0 else { return [] }

      let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
      guard count > 0 else { return [] }
      var devices = Array(repeating: AudioDeviceID(0), count: count)
      let readStatus = unsafe AudioObjectGetPropertyData(
        systemObjectID,
        &address,
        0,
        nil,
        &dataSize,
        &devices,
      )
      guard readStatus == noErr else { return [] }
      return devices
    }

    private func inputChannelCount(deviceID: AudioDeviceID) -> Int {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain,
      )
      var dataSize: UInt32 = 0
      let sizeStatus = unsafe AudioObjectGetPropertyDataSize(
        deviceID,
        &address,
        0,
        nil,
        &dataSize,
      )
      guard sizeStatus == noErr, dataSize > 0 else { return 0 }

      let rawBuffer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(dataSize),
        alignment: MemoryLayout<AudioBufferList>.alignment,
      )
      defer {
        unsafe rawBuffer.deallocate()
      }

      let readStatus = unsafe AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &dataSize,
        rawBuffer,
      )
      guard readStatus == noErr else { return 0 }

      let bufferList = unsafe rawBuffer.assumingMemoryBound(to: AudioBufferList.self)
      let audioBuffers = unsafe UnsafeMutableAudioBufferListPointer(bufferList)
      return unsafe audioBuffers.reduce(into: 0) { partialResult, buffer in
        partialResult += unsafe Int(buffer.mNumberChannels)
      }
    }

    private func stringProperty(objectID: AudioObjectID, selector: AudioObjectPropertySelector)
      -> String?
    {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
      )
      var dataSize = UInt32(MemoryLayout<CFString?>.size)
      let rawValue = UnsafeMutableRawPointer.allocate(
        byteCount: Int(dataSize),
        alignment: MemoryLayout<CFString?>.alignment,
      )
      defer {
        unsafe rawValue.deallocate()
      }
      let status = unsafe AudioObjectGetPropertyData(
        objectID,
        &address,
        0,
        nil,
        &dataSize,
        rawValue,
      )
      guard status == noErr else { return nil }
      let value = unsafe rawValue.assumingMemoryBound(to: CFString?.self).pointee
      return value as String?
    }
  }
#else
  struct UnsupportedPlatformAudioBackend: PlatformAudioBackend {
    let platformName: String = "unsupported"

    func routeChanges() -> AsyncSignalStream<PlatformAudioRouteEvent> {
      let signal = AsyncSignal<PlatformAudioRouteEvent>()
      signal.finish()
      return signal.events()
    }

    @concurrent func availableInputs() async -> [PlatformAudioInputDescriptor] {
      []
    }
  }
#endif
