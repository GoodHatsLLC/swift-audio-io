// © GoodHatsLLC

public import Foundation

/// A platform-neutral audio-system event that may require engine recovery.
public enum AudioSystemEvent: Sendable, Hashable {
  case routeChanged(AudioRouteChange)
  case interruptionBegan
  case interruptionEnded(shouldResume: Bool)
  case mediaServicesLost
  case mediaServicesReset
}

/// A captured route transition with no live platform-session dependency.
public struct AudioRouteChange: Sendable, Hashable {
  public init(
    reason: AudioRouteChangeReason,
    previousRoute: AudioRouteSnapshot?,
    currentRoute: AudioRouteSnapshot,
    session: AudioSessionSnapshot? = nil,
  ) {
    self.reason = reason
    self.previousRoute = previousRoute
    self.currentRoute = currentRoute
    self.session = session
  }

  public let reason: AudioRouteChangeReason
  public let previousRoute: AudioRouteSnapshot?
  public let currentRoute: AudioRouteSnapshot
  public let session: AudioSessionSnapshot?

  public var isInputAvailable: Bool {
    session?.isInputAvailable ?? !currentRoute.inputs.isEmpty
  }

  public var userMessage: String {
    var lines = ["Audio route changed: \(reason.userLabel)"]

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

    if let session, reason.includesSessionSummary {
      lines.append("Session: \(session.summary)")
    }

    return lines.joined(separator: "\n")
  }
}

/// Why the system's active audio route changed.
public enum AudioRouteChangeReason: Sendable, Hashable {
  case deviceDisconnected
  case deviceConnected
  case categoryChanged
  case overridden
  case configurationChanged
  case wokeFromSleep
  case noSuitableRoute
  case unknown

  public var userLabel: String {
    switch self {
    case .deviceDisconnected: "Device disconnected"
    case .deviceConnected: "New device connected"
    case .categoryChanged: "Category changed"
    case .overridden: "Overridden"
    case .configurationChanged: "Route configuration changed"
    case .wokeFromSleep: "Woke from sleep"
    case .noSuitableRoute: "No suitable route"
    case .unknown: "Unknown"
    }
  }

  var includesSessionSummary: Bool {
    switch self {
    case .categoryChanged, .overridden, .configurationChanged, .noSuitableRoute:
      true
    case .deviceDisconnected, .deviceConnected, .wokeFromSleep, .unknown:
      false
    }
  }
}

/// The input and output endpoints captured for one audio route.
public struct AudioRouteSnapshot: Sendable, Hashable {
  public init(inputs: [AudioPortSnapshot], outputs: [AudioPortSnapshot]) {
    self.inputs = inputs
    self.outputs = outputs
  }

  public let inputs: [AudioPortSnapshot]
  public let outputs: [AudioPortSnapshot]

  public var inputsDescription: String {
    describePorts(inputs)
  }

  public var outputsDescription: String {
    describePorts(outputs)
  }

  private func describePorts(_ ports: [AudioPortSnapshot]) -> String {
    guard !ports.isEmpty else { return "none" }
    return ports.map(\.userLabel).joined(separator: ", ")
  }
}

/// A captured audio endpoint.
public struct AudioPortSnapshot: Sendable, Hashable {
  public init(name: String, uid: String, type: String, channelCount: Int) {
    self.name = name
    self.uid = uid
    self.type = type
    self.channelCount = channelCount
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

/// Captured session facts relevant to recovery decisions and diagnostics.
public struct AudioSessionSnapshot: Sendable, Hashable {
  public init(
    category: String,
    mode: String,
    options: [String],
    sampleRate: Double,
    ioBufferDuration: TimeInterval,
    inputNumberOfChannels: Int,
    isInputAvailable: Bool,
  ) {
    self.category = category
    self.mode = mode
    self.options = options
    self.sampleRate = sampleRate
    self.ioBufferDuration = ioBufferDuration
    self.inputNumberOfChannels = inputNumberOfChannels
    self.isInputAvailable = isInputAvailable
  }

  public let category: String
  public let mode: String
  public let options: [String]
  public let sampleRate: Double
  public let ioBufferDuration: TimeInterval
  public let inputNumberOfChannels: Int
  public let isInputAvailable: Bool

  public var summary: String {
    var parts = [category]
    if !mode.isEmpty, mode != "default" {
      parts.append("mode=\(mode)")
    }
    if !options.isEmpty {
      parts.append("options=\(options.joined(separator: ","))")
    }
    if !isInputAvailable {
      parts.append("inputUnavailable")
    }
    parts.append("\(inputNumberOfChannels)ch@\(Int(sampleRate))Hz")
    parts.append("buffer=\(ioBufferDuration)s")
    return parts.joined(separator: "\n")
  }
}
