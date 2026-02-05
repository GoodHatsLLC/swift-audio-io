#if canImport(AVFoundation) && (!os(macOS) || targetEnvironment(macCatalyst))
  import AVFoundation
  import Foundation

  public struct AudioRouteChangeEvent: Sendable, Hashable {
    public init(
      reason: AVAudioSession.RouteChangeReason,
      previousRoute: AVAudioSessionRouteDescription?,
      session: AVAudioSession
    ) {
      self.reason = reason
      self.previousRoute = previousRoute.map(AudioRouteSnapshot.init(route:))
      self.currentRoute = AudioRouteSnapshot(route: session.currentRoute)
      self.session = AudioSessionSnapshot(session: session)
    }

    public let reason: AVAudioSession.RouteChangeReason
    public let previousRoute: AudioRouteSnapshot?
    public let currentRoute: AudioRouteSnapshot
    public let session: AudioSessionSnapshot

    public var userMessage: String {
      var lines: [String] = ["Audio route changed: \(reason.userLabel)"]

      if let previousRoute {
        let inputLine =
          if previousRoute.inputs != currentRoute.inputs {
            "Input: \(previousRoute.inputsDescription) → \(currentRoute.inputsDescription)"
          } else {
            "Input: \(currentRoute.inputsDescription)"
          }
        let outputLine =
          if previousRoute.outputs != currentRoute.outputs {
            "Output: \(previousRoute.outputsDescription) → \(currentRoute.outputsDescription)"
          } else {
            "Output: \(currentRoute.outputsDescription)"
          }
        lines.append(inputLine)
        lines.append(outputLine)
      } else {
        lines.append("Input: \(currentRoute.inputsDescription)")
        lines.append("Output: \(currentRoute.outputsDescription)")
      }

      if shouldIncludeSessionSummary {
        lines.append("Session: \(session.summary)")
      }

      return lines.joined(separator: "\n")
    }

    private var shouldIncludeSessionSummary: Bool {
      switch reason {
      case .categoryChange, .override, .routeConfigurationChange, .noSuitableRouteForCategory:
        return true
      default:
        return false
      }
    }
  }

  public struct AudioRouteSnapshot: Sendable, Hashable {
    public init(route: AVAudioSessionRouteDescription) {
      self.inputs = route.inputs.map(AudioPortSnapshot.init(port:))
      self.outputs = route.outputs.map(AudioPortSnapshot.init(port:))
    }

    public let inputs: [AudioPortSnapshot]
    public let outputs: [AudioPortSnapshot]

    public var inputsDescription: String { describePorts(inputs) }
    public var outputsDescription: String { describePorts(outputs) }

    private func describePorts(_ ports: [AudioPortSnapshot]) -> String {
      guard !ports.isEmpty else { return "none" }
      return ports.map(\.userLabel).joined(separator: ", ")
    }
  }

  public struct AudioPortSnapshot: Sendable, Hashable {
    public init(port: AVAudioSessionPortDescription) {
      self.name = port.portName
      self.uid = port.uid
      self.type = port.portType.rawValue
      self.channelCount = port.channels?.count ?? 0
    }

    public let name: String
    public let uid: String
    public let type: String
    public let channelCount: Int

    public var userLabel: String {
      if channelCount > 0 {
        return "\(name) (\(type), \(channelCount)ch)"
      }
      return "\(name) (\(type))"
    }
  }

  public struct AudioSessionSnapshot: Sendable, Hashable {
    public init(session: AVAudioSession) {
      self.category = session.category.rawValue
      self.mode = session.mode.rawValue
      self.options = AVAudioSession.CategoryOptions.userLabels(for: session.categoryOptions)
      self.sampleRate = session.sampleRate
      self.ioBufferDuration = session.ioBufferDuration
      self.inputNumberOfChannels = session.inputNumberOfChannels
      self.isInputAvailable = session.isInputAvailable
    }

    public let category: String
    public let mode: String
    public let options: [String]
    public let sampleRate: Double
    public let ioBufferDuration: TimeInterval
    public let inputNumberOfChannels: Int
    public let isInputAvailable: Bool

    public var summary: String {
      var parts: [String] = []
      parts.append(category)
      if mode != AVAudioSession.Mode.default.rawValue {
        parts.append("mode=\(mode)")
      }
      if !options.isEmpty {
        parts.append("options=\(options.joined(separator: ","))")
      }
      if !isInputAvailable {
        parts.append("inputUnavailable")
      }
      parts.append("\(inputNumberOfChannels)ch@\(Int(sampleRate))Hz")
      parts.append("buffer=\(ioBufferDuration/1000.0)s")
      return parts.joined(separator: " ")
    }
  }

  extension AVAudioSession.RouteChangeReason {
    fileprivate var userLabel: String {
      switch self {
      case .oldDeviceUnavailable:
        "Device disconnected"
      case .newDeviceAvailable:
        "New device connected"
      case .categoryChange:
        "Category changed"
      case .override:
        "Overridden"
      case .routeConfigurationChange:
        "Route configuration changed"
      case .wakeFromSleep:
        "Woke from sleep"
      case .noSuitableRouteForCategory:
        "No suitable route"
      case .unknown:
        "Unknown"
      @unknown default:
        "Unknown"
      }
    }
  }

  extension AVAudioSession.CategoryOptions {
    fileprivate static func userLabels(for options: AVAudioSession.CategoryOptions) -> [String] {
      var labels: [String] = []

      if options.contains(.mixWithOthers) { labels.append("mixWithOthers") }
      if options.contains(.duckOthers) { labels.append("duckOthers") }
      if options.contains(.interruptSpokenAudioAndMixWithOthers) {
        labels.append("interruptSpokenAudioAndMixWithOthers")
      }

      #if os(iOS) || os(tvOS) || os(visionOS)
        if options.contains(.allowBluetoothA2DP) { labels.append("allowBluetoothA2DP") }
        if options.contains(.allowBluetoothHFP) { labels.append("allowBluetoothHFP") }
        if options.contains(.allowAirPlay) { labels.append("allowAirPlay") }
        if options.contains(.defaultToSpeaker) { labels.append("defaultToSpeaker") }
        if options.contains(.overrideMutedMicrophoneInterruption) {
          labels.append("overrideMutedMicrophoneInterruption")
        }

        #if !targetEnvironment(macCatalyst)
          if #available(iOS 26.0, *),
            options.contains(.bluetoothHighQualityRecording)
          {
            labels.append("bluetoothHighQualityRecording")
          }
        #endif
      #endif

      return labels
    }
  }
#endif
