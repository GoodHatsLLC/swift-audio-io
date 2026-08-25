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
  @concurrent func currentRoute() async -> AudioRouteSnapshot
  /// The capture-relevant facts of the default input — its nominal rate and
  /// channel count — or `nil` when the platform cannot report them. Without
  /// these a route event carries no `AudioInputFacts`, and a live recording
  /// has to rebuild its tap on every event because it cannot prove nothing
  /// moved.
  @concurrent func currentInputSessionSnapshot() async -> AudioSessionSnapshot?
}

extension PlatformAudioBackend {
  @concurrent func currentInputSessionSnapshot() async -> AudioSessionSnapshot? {
    nil
  }

  @concurrent func currentRoute() async -> AudioRouteSnapshot {
    let inputs = await availableInputs()
      .filter(\.isDefault)
      .map(\.portSnapshot)
    return AudioRouteSnapshot(inputs: inputs, outputs: [])
  }
}

extension PlatformAudioInputDescriptor {
  var portSnapshot: AudioPortSnapshot {
    AudioPortSnapshot(
      name: name,
      uid: id,
      type: String(describing: type),
      channelCount: channelCount,
    )
  }
}

enum PlatformAudioBackendFactory {
  /// On iOS the audio environment talks to `AVAudioSession` directly rather
  /// than through this seam: route handling needs the change reason and the
  /// previous route, which `PlatformAudioRouteEvent` does not carry. See
  /// `AudioEnvironment.notifications` and `AudioRouteObserver`.
  static func makeDefault() -> any PlatformAudioBackend {
    #if os(macOS)
      return MacOSPlatformAudioBackend()
    #else
      return UnsupportedPlatformAudioBackend()
    #endif
  }
}

#if os(macOS)
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

    @concurrent func currentRoute() async -> AudioRouteSnapshot {
      AudioRouteSnapshot(
        inputs: defaultDevicePort(
          selector: kAudioHardwarePropertyDefaultInputDevice,
          scope: kAudioObjectPropertyScopeInput,
        ).map { [$0] } ?? [],
        outputs: defaultDevicePort(
          selector: kAudioHardwarePropertyDefaultOutputDevice,
          scope: kAudioObjectPropertyScopeOutput,
        ).map { [$0] } ?? [],
      )
    }

    private struct CoreAudioInput {
      let uid: String
      let name: String
      let type: AudioInput.InputType
      let channelCount: Int
    }

    private struct RouteSignature: Hashable {
      let defaultInputID: String?
      let defaultOutputID: String?
      let inputIDs: [String]
      let outputIDs: [String]
      /// The default input's format is part of the route: a device that
      /// changes its nominal rate or channel count without changing identity
      /// posts nothing on macOS, and a live tap built at the old format would
      /// otherwise keep running blind.
      let defaultInputSampleRate: Double?
      let defaultInputChannelCount: Int?
    }

    private func routeSignature() -> RouteSignature {
      let devices = deviceIDs()
      let defaultInput = defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
      return RouteSignature(
        defaultInputID: defaultInputDeviceUID(),
        defaultOutputID: defaultDeviceUID(
          selector: kAudioHardwarePropertyDefaultOutputDevice,
        ),
        inputIDs: deviceUIDs(devices, scope: kAudioObjectPropertyScopeInput),
        outputIDs: deviceUIDs(devices, scope: kAudioObjectPropertyScopeOutput),
        defaultInputSampleRate: defaultInput.flatMap(nominalSampleRate(deviceID:)),
        defaultInputChannelCount: defaultInput.map {
          channelCount(deviceID: $0, scope: kAudioObjectPropertyScopeInput)
        },
      )
    }

    @concurrent func currentInputSessionSnapshot() async -> AudioSessionSnapshot? {
      guard let deviceID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
      else {
        return nil
      }
      let channels = channelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput)
      guard let sampleRate = nominalSampleRate(deviceID: deviceID) else { return nil }
      return AudioSessionSnapshot(
        category: "",
        mode: "default",
        options: [],
        sampleRate: sampleRate,
        ioBufferDuration: 0,
        inputNumberOfChannels: channels,
        isInputAvailable: channels > 0,
      )
    }

    private func nominalSampleRate(deviceID: AudioDeviceID) -> Double? {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
      )
      var value: Float64 = 0
      var dataSize = UInt32(MemoryLayout<Float64>.size)
      let status = unsafe AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &dataSize,
        &value,
      )
      guard status == noErr, value > 0 else { return nil }
      return value
    }

    private func deviceUIDs(
      _ devices: [AudioDeviceID],
      scope: AudioObjectPropertyScope,
    ) -> [String] {
      devices.compactMap { deviceID in
        guard channelCount(deviceID: deviceID, scope: scope) > 0 else { return nil }
        return stringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
      }
      .sorted()
    }

    private func audioInputDevices() -> [CoreAudioInput] {
      deviceIDs().compactMap { deviceID in
        let channels = channelCount(
          deviceID: deviceID,
          scope: kAudioObjectPropertyScopeInput,
        )
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
      defaultDeviceUID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private func defaultDeviceUID(selector: AudioObjectPropertySelector) -> String? {
      guard let deviceID = defaultDeviceID(selector: selector) else { return nil }
      return stringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private func defaultDevicePort(
      selector: AudioObjectPropertySelector,
      scope: AudioObjectPropertyScope,
    ) -> AudioPortSnapshot? {
      guard let deviceID = defaultDeviceID(selector: selector) else { return nil }
      let channels = channelCount(deviceID: deviceID, scope: scope)
      guard channels > 0,
        let uid = stringProperty(
          objectID: deviceID,
          selector: kAudioDevicePropertyDeviceUID,
        )
      else {
        return nil
      }
      let name =
        stringProperty(objectID: deviceID, selector: kAudioObjectPropertyName)
        ?? "Audio Device \(uid)"
      let type = AudioInput.InputType(
        coreAudioTransportType: transportType(deviceID: deviceID),
      )
      return AudioPortSnapshot(
        name: name,
        uid: uid,
        type: String(describing: type),
        channelCount: channels,
      )
    }

    private func defaultDeviceID(
      selector: AudioObjectPropertySelector,
    ) -> AudioDeviceID? {
      let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
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
      return deviceID
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

    private func channelCount(
      deviceID: AudioDeviceID,
      scope: AudioObjectPropertyScope,
    ) -> Int {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
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
