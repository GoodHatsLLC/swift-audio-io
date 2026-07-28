// © GoodHatsLLC

package import Foundation

package struct PlatformAudioInputSnapshot: Hashable, Sendable {
  package let capabilities: AudioInputConfigurationCapabilities
  package let applied: AppliedAudioInputConfiguration?

  package init(
    capabilities: AudioInputConfigurationCapabilities,
    applied: AppliedAudioInputConfiguration?,
  ) {
    self.capabilities = capabilities
    self.applied = applied
  }
}

package struct PlatformAudioInputConfigurationPlan: Hashable, Sendable {
  package let requestedGeneration: UInt64
  package let preferredInput: AudioInputSelection?
  package let resolvedInput: AudioInputSelection
  package let source: AudioSourceSelection?
  package let format: InputConfiguration
  package let processing: AudioInputProcessingPreference

  package init(
    requestedGeneration: UInt64,
    preferredInput: AudioInputSelection?,
    resolvedInput: AudioInputSelection,
    source: AudioSourceSelection?,
    format: InputConfiguration,
    processing: AudioInputProcessingPreference,
  ) {
    self.requestedGeneration = requestedGeneration
    self.preferredInput = preferredInput
    self.resolvedInput = resolvedInput
    self.source = source
    self.format = format
    self.processing = processing
  }
}

/// Internal platform seam for input discovery, mutation, and readback.
///
/// iOS, macOS, and deterministic tests provide independent adapters. The
/// public interface remains the request/state pair on `AudioEnvironmentManager`.
package protocol PlatformAudioInputConfigurationAdapter: Sendable {
  func discover() async -> PlatformAudioInputSnapshot
  func apply(
    _ plan: PlatformAudioInputConfigurationPlan,
  ) async throws -> PlatformAudioInputSnapshot
}

package enum AudioInputConfigurationResolution: Hashable, Sendable {
  case deferred(AudioInputConfigurationDeferral)
  case unsupported(AudioInputConfigurationIssue)
  case apply(PlatformAudioInputConfigurationPlan)
}

package enum AudioInputConfigurationResolver {
  package static func resolve(
    requested: AudioInputConfigurationRequest,
    generation: UInt64,
    capabilities: AudioInputConfigurationCapabilities,
    currentApplied: AppliedAudioInputConfiguration?,
  ) -> AudioInputConfigurationResolution {
    guard capabilities.discovery == .resolved else {
      return .deferred(.mediaServicesUnavailable)
    }

    let resolvedInput: AudioInputSelection
    let preferredInput: AudioInputSelection?
    switch requested.input {
    case .systemDefault:
      guard let effectiveInput = capabilities.effectiveInput else {
        return .deferred(.mediaServicesUnavailable)
      }
      resolvedInput = effectiveInput
      preferredInput = nil
    case .specific(let id):
      guard let input = capabilities.inputs.first(where: { $0.id == id }) else {
        return .deferred(.requestedInputUnavailable(id: id))
      }
      resolvedInput = input
      preferredInput = input
    }

    var options = capabilities.sourceOptions.filter { $0.inputID == resolvedInput.id }
    switch requested.source {
    case .automatic:
      break
    case .specific(let sourceID, let polarPatternID):
      guard options.contains(where: { $0.source?.id == sourceID }) else {
        return .unsupported(.unsupportedSource(id: sourceID))
      }
      if let polarPatternID,
        !options.contains(where: {
          $0.source?.id == sourceID && $0.source?.polarPatternID == polarPatternID
        })
      {
        return .unsupported(.unsupportedPolarPattern(id: polarPatternID))
      }
      options = options.filter {
        $0.source?.id == sourceID
          && (polarPatternID == nil || $0.source?.polarPatternID == polarPatternID)
      }
    }

    if let exactChannels = requested.channels.exactChannelCount {
      options = options.filter { $0.channels == exactChannels }
      guard !options.isEmpty else {
        return .unsupported(.unsupportedChannels(exactChannels))
      }
    }

    guard
      let option = options.sorted(by: optionPreference).first
        ?? sourceFreeOption(for: resolvedInput, requested: requested.channels)
    else {
      return .unsupported(
        .unsupportedChannels(requested.channels.exactChannelCount ?? .mono),
      )
    }

    let sampleRate: SampleRate
    switch requested.sampleRate {
    case .automatic:
      if let currentApplied, currentApplied.input.id == resolvedInput.id {
        sampleRate = currentApplied.format.sampleRate
      } else if capabilities.likelySampleRates.contains(.dvd) {
        sampleRate = .dvd
      } else {
        sampleRate = capabilities.likelySampleRates.first ?? .dvd
      }
    case .exact(let requestedRate):
      sampleRate = requestedRate
    }

    return .apply(
      PlatformAudioInputConfigurationPlan(
        requestedGeneration: generation,
        preferredInput: preferredInput,
        resolvedInput: resolvedInput,
        source: option.source,
        format: InputConfiguration(sampleRate: sampleRate, channels: option.channels),
        processing: requested.processing,
      ),
    )
  }

  private static func optionPreference(
    _ lhs: AudioSourceConfigurationOption,
    _ rhs: AudioSourceConfigurationOption,
  ) -> Bool {
    if lhs.channels != rhs.channels {
      return lhs.channels > rhs.channels
    }
    return lhs.id < rhs.id
  }

  private static func sourceFreeOption(
    for input: AudioInputSelection,
    requested: AudioChannelPreference,
  ) -> AudioSourceConfigurationOption? {
    let channels = requested.exactChannelCount ?? (input.channelCount >= .stereo ? .stereo : .mono)
    guard channels <= input.channelCount else { return nil }
    return AudioSourceConfigurationOption(inputID: input.id, source: nil, channels: channels)
  }
}

@MainActor
package final class AudioInputConfigurationRequestStore {
  package static let storageKey = "aio.audio_env.input_configuration_request.v1"

  private let defaults: UserDefaults

  package init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  package func load() -> AudioInputConfigurationRequest {
    guard let data = defaults.data(forKey: Self.storageKey) else {
      return .automatic
    }
    return (try? JSONDecoder().decode(AudioInputConfigurationRequest.self, from: data))
      ?? .automatic
  }

  package func save(_ request: AudioInputConfigurationRequest) {
    guard let data = try? JSONEncoder().encode(request) else { return }
    defaults.set(data, forKey: Self.storageKey)
  }
}

/// Owns requested state, persistence, serialized reconciliation, and readback
/// classification for one audio environment.
@MainActor
package final class AudioInputConfigurationCoordinator {
  package private(set) var state: AudioInputConfigurationState

  private let adapter: any PlatformAudioInputConfigurationAdapter
  private let store: AudioInputConfigurationRequestStore
  private var generation: UInt64

  package init(
    defaults: UserDefaults,
    adapter: any PlatformAudioInputConfigurationAdapter,
  ) {
    self.adapter = adapter
    store = AudioInputConfigurationRequestStore(defaults: defaults)
    let requested = store.load()
    generation = 0
    state = .initial(requested: requested)
  }

  package func submit(
    _ requested: AudioInputConfigurationRequest,
    isRunning: Bool,
    isActive: Bool,
  ) async -> AudioInputConfigurationState {
    generation &+= 1
    store.save(requested)
    state = AudioInputConfigurationState(
      requested: requested,
      requestedGeneration: generation,
      applied: isActive ? state.applied : nil,
      capabilities: state.capabilities,
      reconciliation: isRunning
        ? (isActive ? .reconciling : .deferred(.sessionInactive))
        : .deferred(.environmentNotRunning),
    )
    guard isRunning, isActive else { return state }
    return await reconcile(isRunning: true, isActive: true)
  }

  package func reconcile(
    isRunning: Bool,
    isActive: Bool,
    forcePlatformApply: Bool = false,
  ) async -> AudioInputConfigurationState {
    while true {
      let requested = state.requested
      let requestedGeneration = generation
      let snapshot = await adapter.discover()
      guard requestedGeneration == generation else { continue }

      let applied = isActive ? snapshot.applied : nil
      guard isRunning else {
        return publish(
          requested: requested,
          generation: requestedGeneration,
          snapshot: snapshot,
          applied: nil,
          reconciliation: .deferred(.environmentNotRunning),
        )
      }
      guard isActive else {
        return publish(
          requested: requested,
          generation: requestedGeneration,
          snapshot: snapshot,
          applied: nil,
          reconciliation: .deferred(.sessionInactive),
        )
      }

      switch AudioInputConfigurationResolver.resolve(
        requested: requested,
        generation: requestedGeneration,
        capabilities: snapshot.capabilities,
        currentApplied: applied,
      ) {
      case .deferred(let reason):
        return publish(
          requested: requested,
          generation: requestedGeneration,
          snapshot: snapshot,
          applied: applied,
          reconciliation: .deferred(reason),
        )
      case .unsupported(let issue):
        return publish(
          requested: requested,
          generation: requestedGeneration,
          snapshot: snapshot,
          applied: applied,
          reconciliation: .unsatisfied(issue),
        )
      case .apply(let plan):
        // Route notifications and periodic discovery are refreshes, not new
        // configuration intent. Reissuing satisfied AVAudioSession preferences
        // can generate another route notification and keep the recording tap
        // in a stop/reinstall loop. Activation and orientation changes opt into
        // one forced write because the platform may have discarded state that
        // is not fully represented by the semantic readback.
        if !forcePlatformApply,
          state.requestedGeneration == requestedGeneration,
          state.reconciliation == .satisfied,
          Self.classify(readback: applied, expected: plan) == .satisfied
        {
          return publish(
            requested: requested,
            generation: requestedGeneration,
            snapshot: snapshot,
            applied: applied,
            reconciliation: .satisfied,
          )
        }
        _ = publish(
          requested: requested,
          generation: requestedGeneration,
          snapshot: snapshot,
          applied: applied,
          reconciliation: .reconciling,
        )
        do {
          let readback = try await adapter.apply(plan)
          guard requestedGeneration == generation else {
            state = AudioInputConfigurationState(
              requested: state.requested,
              requestedGeneration: generation,
              applied: readback.applied,
              capabilities: readback.capabilities,
              reconciliation: .reconciling,
            )
            continue
          }
          let reconciliation = Self.classify(readback: readback.applied, expected: plan)
          return publish(
            requested: requested,
            generation: requestedGeneration,
            snapshot: readback,
            applied: readback.applied,
            reconciliation: reconciliation,
          )
        } catch {
          let readback = await adapter.discover()
          guard requestedGeneration == generation else { continue }
          return publish(
            requested: requested,
            generation: requestedGeneration,
            snapshot: readback,
            applied: readback.applied,
            reconciliation: .unsatisfied(.platformOperationFailed(String(describing: error))),
          )
        }
      }
    }
  }

  package func markUnavailable(
    _ deferral: AudioInputConfigurationDeferral,
  ) -> AudioInputConfigurationState {
    state = AudioInputConfigurationState(
      requested: state.requested,
      requestedGeneration: generation,
      applied: nil,
      capabilities: state.capabilities,
      reconciliation: .deferred(deferral),
    )
    return state
  }

  private func publish(
    requested: AudioInputConfigurationRequest,
    generation: UInt64,
    snapshot: PlatformAudioInputSnapshot,
    applied: AppliedAudioInputConfiguration?,
    reconciliation: AudioInputConfigurationReconciliation,
  ) -> AudioInputConfigurationState {
    state = AudioInputConfigurationState(
      requested: requested,
      requestedGeneration: generation,
      applied: applied,
      capabilities: snapshot.capabilities,
      reconciliation: reconciliation,
    )
    return state
  }

  private static func classify(
    readback: AppliedAudioInputConfiguration?,
    expected: PlatformAudioInputConfigurationPlan,
  ) -> AudioInputConfigurationReconciliation {
    guard let readback else {
      return .unsatisfied(.readbackMismatch(expected: expected.format, actual: nil))
    }
    guard readback.format.sampleRate == expected.format.sampleRate else {
      return .unsatisfied(
        .rejectedSampleRate(
          requested: expected.format.sampleRate,
          applied: readback.format.sampleRate,
        ),
      )
    }
    guard readback.input.id == expected.resolvedInput.id,
      readback.format.channels == expected.format.channels,
      readback.processing == expected.processing,
      sourceMatches(readback.source, expected.source)
    else {
      return .unsatisfied(
        .readbackMismatch(expected: expected.format, actual: readback.format),
      )
    }
    return .satisfied
  }

  private static func sourceMatches(
    _ applied: AudioSourceSelection?,
    _ expected: AudioSourceSelection?,
  ) -> Bool {
    switch (applied, expected) {
    case (nil, nil):
      true
    case (.some(let applied), .some(let expected)):
      applied.id == expected.id
        && (expected.polarPatternID == nil
          || applied.polarPatternID == expected.polarPatternID)
    case (.none, .some), (.some, .none):
      false
    }
  }
}
