// © GoodHatsLLC

/// Durable user intent for microphone input configuration.
///
/// A request is meaningful before an audio route exists. It is never rewritten
/// to match a temporary platform fallback; callers compare it with
/// ``AppliedAudioInputConfiguration`` to present pending or unsatisfied state.
public struct AudioInputConfigurationRequest: Codable, Hashable, Sendable {
  public var input: AudioInputPreference
  public var source: AudioSourcePreference
  public var channels: AudioChannelPreference
  public var sampleRate: AudioSampleRatePreference
  public var processing: AudioInputProcessingPreference

  public init(
    input: AudioInputPreference = .systemDefault,
    source: AudioSourcePreference = .automatic,
    channels: AudioChannelPreference = .automatic,
    sampleRate: AudioSampleRatePreference = .automatic,
    processing: AudioInputProcessingPreference = .processed,
  ) {
    self.input = input
    self.source = source
    self.channels = channels
    self.sampleRate = sampleRate
    self.processing = processing
  }

  public static let automatic = AudioInputConfigurationRequest()
}

public enum AudioInputPreference: Codable, Hashable, Sendable {
  case systemDefault
  case specific(id: String)
}

public enum AudioSourcePreference: Codable, Hashable, Sendable {
  case automatic
  case specific(sourceID: String, polarPatternID: String?)
}

public enum AudioChannelPreference: Codable, Hashable, Sendable {
  case automatic
  case mono
  case stereo

  public var exactChannelCount: ChannelCount? {
    switch self {
    case .automatic:
      nil
    case .mono:
      .mono
    case .stereo:
      .stereo
    }
  }
}

public enum AudioSampleRatePreference: Codable, Hashable, Sendable {
  case automatic
  case exact(SampleRate)
}

public enum AudioInputProcessingPreference: Codable, Hashable, Sendable {
  case processed
  case measurement
}

/// A platform-neutral source identity suitable for state and diagnostics.
public struct AudioSourceSelection: Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let polarPatternID: String?
  public let polarPatternName: String?

  public init(
    id: String,
    name: String,
    polarPatternID: String? = nil,
    polarPatternName: String? = nil,
  ) {
    self.id = id
    self.name = name
    self.polarPatternID = polarPatternID
    self.polarPatternName = polarPatternName
  }
}

/// One valid source, polar-pattern, and channel-count combination.
///
/// `source` is `nil` for inputs whose platform exposes channels but no
/// separately selectable source.
public struct AudioSourceConfigurationOption: Hashable, Identifiable, Sendable {
  public let inputID: String
  public let source: AudioSourceSelection?
  public let channels: ChannelCount

  public init(
    inputID: String,
    source: AudioSourceSelection?,
    channels: ChannelCount,
  ) {
    self.inputID = inputID
    self.source = source
    self.channels = channels
  }

  public var id: String {
    [
      inputID,
      source?.id ?? "_default",
      source?.polarPatternID ?? "_automatic",
      String(channels.count),
    ].joined(separator: "/")
  }
}

/// Exact platform state observed after configuration readback.
public struct AppliedAudioInputConfiguration: Hashable, Sendable {
  public let input: AudioInputSelection
  public let source: AudioSourceSelection?
  public let format: InputConfiguration
  public let processing: AudioInputProcessingPreference

  public init(
    input: AudioInputSelection,
    source: AudioSourceSelection?,
    format: InputConfiguration,
    processing: AudioInputProcessingPreference,
  ) {
    self.input = input
    self.source = source
    self.format = format
    self.processing = processing
  }
}

public struct AudioInputConfigurationCapabilities: Hashable, Sendable {
  public enum Discovery: Hashable, Sendable {
    case discovering
    case resolved
    case unavailable
  }

  public let discovery: Discovery
  public let inputs: [AudioInputSelection]
  public let effectiveInput: AudioInputSelection?
  public let sourceOptions: [AudioSourceConfigurationOption]
  public let likelySampleRates: [SampleRate]

  public init(
    discovery: Discovery,
    inputs: [AudioInputSelection],
    effectiveInput: AudioInputSelection?,
    sourceOptions: [AudioSourceConfigurationOption],
    likelySampleRates: [SampleRate],
  ) {
    self.discovery = discovery
    self.inputs = inputs
    self.effectiveInput = effectiveInput
    self.sourceOptions = sourceOptions
    self.likelySampleRates = likelySampleRates
  }

  public static let discovering = AudioInputConfigurationCapabilities(
    discovery: .discovering,
    inputs: [],
    effectiveInput: nil,
    sourceOptions: [],
    likelySampleRates: [],
  )
}

public enum AudioInputConfigurationDeferral: Hashable, Sendable, CustomStringConvertible {
  case environmentNotRunning
  case sessionInactive
  case requestedInputUnavailable(id: String)
  case mediaServicesUnavailable

  public var description: String {
    switch self {
    case .environmentNotRunning:
      "The audio environment is not running."
    case .sessionInactive:
      "The microphone is inactive."
    case .requestedInputUnavailable(let id):
      "The requested input \(id) is temporarily unavailable."
    case .mediaServicesUnavailable:
      "Audio services are temporarily unavailable."
    }
  }
}

public enum AudioInputConfigurationIssue: Hashable, Sendable, CustomStringConvertible {
  case unsupportedSource(id: String)
  case unsupportedPolarPattern(id: String)
  case unsupportedChannels(ChannelCount)
  case rejectedSampleRate(requested: SampleRate, applied: SampleRate?)
  case platformOperationFailed(String)
  case readbackMismatch(expected: InputConfiguration, actual: InputConfiguration?)

  public var description: String {
    switch self {
    case .unsupportedSource(let id):
      "The source \(id) is not supported by the requested input."
    case .unsupportedPolarPattern(let id):
      "The polar pattern \(id) is not supported by the requested source."
    case .unsupportedChannels(let channels):
      "\(channels) is not supported by the requested input and source."
    case .rejectedSampleRate(let requested, let applied):
      "The requested sample rate \(requested) was rejected"
        + (applied.map { "; the platform applied \($0)." } ?? ".")
    case .platformOperationFailed(let message):
      "The platform could not apply the input configuration: \(message)"
    case .readbackMismatch(let expected, let actual):
      "The platform readback \(actual.map(String.init(describing:)) ?? "none") did not match \(expected)."
    }
  }
}

public enum AudioInputConfigurationReconciliation: Hashable, Sendable {
  case discovering
  case deferred(AudioInputConfigurationDeferral)
  case reconciling
  case satisfied
  case unsatisfied(AudioInputConfigurationIssue)
}

public struct AudioInputConfigurationState: Hashable, Sendable {
  public let requested: AudioInputConfigurationRequest
  public let requestedGeneration: UInt64
  public let applied: AppliedAudioInputConfiguration?
  public let capabilities: AudioInputConfigurationCapabilities
  public let reconciliation: AudioInputConfigurationReconciliation

  public init(
    requested: AudioInputConfigurationRequest,
    requestedGeneration: UInt64,
    applied: AppliedAudioInputConfiguration?,
    capabilities: AudioInputConfigurationCapabilities,
    reconciliation: AudioInputConfigurationReconciliation,
  ) {
    self.requested = requested
    self.requestedGeneration = requestedGeneration
    self.applied = applied
    self.capabilities = capabilities
    self.reconciliation = reconciliation
  }

  public static func initial(
    requested: AudioInputConfigurationRequest = .automatic,
  ) -> AudioInputConfigurationState {
    AudioInputConfigurationState(
      requested: requested,
      requestedGeneration: 0,
      applied: nil,
      capabilities: .discovering,
      reconciliation: .discovering,
    )
  }
}

/// Immutable microphone values admitted through the configuration barrier.
public struct SettledMicrophoneInputConfiguration: Hashable, Sendable {
  public let format: InputConfiguration
  public let preferredInput: AudioInputSelection?
  public let source: AudioSourceSelection?
  public let requestGeneration: UInt64

  public init(
    format: InputConfiguration,
    preferredInput: AudioInputSelection?,
    source: AudioSourceSelection?,
    requestGeneration: UInt64,
  ) {
    self.format = format
    self.preferredInput = preferredInput
    self.source = source
    self.requestGeneration = requestGeneration
  }
}
