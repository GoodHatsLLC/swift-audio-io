// © GoodHatsLLC

import Foundation
import Testing
import Tools

@testable import AIOAudioSession

struct AudioInputConfigurationCoordinatorTests {
  enum AdapterFailure: Error {
    case rejected
  }

  actor ScriptedAdapter: PlatformAudioInputConfigurationAdapter {
    var snapshot: PlatformAudioInputSnapshot
    var appliedPlans: [PlatformAudioInputConfigurationPlan] = []
    let throwsOnApply: Bool

    init(
      snapshot: PlatformAudioInputSnapshot,
      throwsOnApply: Bool = false,
    ) {
      self.snapshot = snapshot
      self.throwsOnApply = throwsOnApply
    }

    func discover() async -> PlatformAudioInputSnapshot {
      snapshot
    }

    func apply(
      _ plan: PlatformAudioInputConfigurationPlan,
    ) async throws -> PlatformAudioInputSnapshot {
      appliedPlans.append(plan)
      if throwsOnApply {
        throw AdapterFailure.rejected
      }
      return snapshot
    }

    func setSnapshot(_ snapshot: PlatformAudioInputSnapshot) {
      self.snapshot = snapshot
    }

    func plans() -> [PlatformAudioInputConfigurationPlan] {
      appliedPlans
    }
  }

  actor BlockingAdapter: PlatformAudioInputConfigurationAdapter {
    private let input: AudioInputSelection
    private let applyStarted = AsyncContinuation<Void>()
    private let releaseFirstApply = AsyncContinuation<Void>()
    private var blocksNextApply = true

    init(input: AudioInputSelection) {
      self.input = input
    }

    func discover() async -> PlatformAudioInputSnapshot {
      snapshot(appliedChannels: nil)
    }

    func apply(
      _ plan: PlatformAudioInputConfigurationPlan,
    ) async throws -> PlatformAudioInputSnapshot {
      if blocksNextApply {
        blocksNextApply = false
        try? applyStarted.yield()
        await releaseFirstApply()
      }
      return snapshot(appliedChannels: plan.format.channels)
    }

    func waitForFirstApply() async {
      await applyStarted()
    }

    func release() {
      try? releaseFirstApply.yield()
    }

    private func snapshot(
      appliedChannels: ChannelCount?
    ) -> PlatformAudioInputSnapshot {
      PlatformAudioInputSnapshot(
        capabilities: AudioInputConfigurationCapabilities(
          discovery: .resolved,
          inputs: [input],
          effectiveInput: input,
          sourceOptions: [
            AudioSourceConfigurationOption(inputID: input.id, source: nil, channels: .mono),
            AudioSourceConfigurationOption(inputID: input.id, source: nil, channels: .stereo),
          ],
          likelySampleRates: [.dvd],
        ),
        applied: appliedChannels.map {
          AppliedAudioInputConfiguration(
            input: input,
            source: nil,
            format: InputConfiguration(sampleRate: .dvd, channels: $0),
            processing: .processed,
          )
        },
      )
    }
  }

  @Test
  @MainActor
  func `unresolved startup retains automatic request and publishes discovery facts`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(
      snapshot: PlatformAudioInputSnapshot(
        capabilities: .discovering,
        applied: nil,
      ),
    )
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)

    let state = await coordinator.reconcile(isRunning: true, isActive: false)

    #expect(state.requested == .automatic)
    #expect(state.requestedGeneration == 0)
    #expect(state.capabilities.discovery == .discovering)
    #expect(state.applied == nil)
    #expect(state.reconciliation == .deferred(.sessionInactive))
  }

  @Test
  @MainActor
  func `inactive stereo request persists without touching the platform`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: nil))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    let state = await coordinator.submit(request, isRunning: true, isActive: false)

    #expect(state.requested.channels == .stereo)
    #expect(state.applied == nil)
    #expect(state.reconciliation == .deferred(.sessionInactive))
    #expect(await adapter.plans().isEmpty)

    let restored = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    #expect(restored.state.requested.channels == .stereo)
  }

  @Test
  @MainActor
  func `active request is satisfied only after exact stereo readback`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: .stereo))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    let state = await coordinator.submit(request, isRunning: true, isActive: true)

    #expect(state.requested.channels == .stereo)
    #expect(state.applied?.format.channels == .stereo)
    #expect(state.reconciliation == .satisfied)
    #expect(await adapter.plans().map(\.format.channels) == [.stereo])
  }

  @Test
  @MainActor
  func `refreshing an already satisfied request does not touch the platform`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: .stereo))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    _ = await coordinator.submit(request, isRunning: true, isActive: true)
    let refreshed = await coordinator.reconcile(isRunning: true, isActive: true)

    #expect(refreshed.reconciliation == .satisfied)
    let appliedPlans = await adapter.plans()
    #expect(
      appliedPlans.map(\.format.channels) == [.stereo],
      "A capability refresh reapplied the satisfied route \(appliedPlans.count) times.",
    )
  }

  @Test
  @MainActor
  func `forcing a satisfied reconciliation reapplies platform preferences once`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: .stereo))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    _ = await coordinator.submit(request, isRunning: true, isActive: true)
    let reconciled = await coordinator.reconcile(
      isRunning: true,
      isActive: true,
      forcePlatformApply: true,
    )
    let notificationRefresh = await coordinator.reconcile(isRunning: true, isActive: true)

    #expect(reconciled.reconciliation == .satisfied)
    #expect(notificationRefresh.reconciliation == .satisfied)
    #expect(await adapter.plans().map(\.format.channels) == [.stereo, .stereo])
  }

  @Test
  @MainActor
  func `activation reconciles the stereo request submitted while inactive`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: .stereo))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    _ = await coordinator.submit(request, isRunning: true, isActive: false)
    let state = await coordinator.reconcile(isRunning: true, isActive: true)

    #expect(state.requested.channels == .stereo)
    #expect(state.reconciliation == .satisfied)
    #expect(await adapter.plans().map(\.format.channels) == [.stereo])
  }

  @Test
  func `automatic resolution chooses stereo when available and mono otherwise`() {
    let stereo = AudioInputConfigurationResolver.resolve(
      requested: .automatic,
      generation: 1,
      capabilities: stereoSnapshot(appliedChannels: nil).capabilities,
      currentApplied: nil,
    )
    let mono = AudioInputConfigurationResolver.resolve(
      requested: .automatic,
      generation: 2,
      capabilities: monoSnapshot(appliedChannels: nil).capabilities,
      currentApplied: nil,
    )

    guard case .apply(let stereoPlan) = stereo, case .apply(let monoPlan) = mono else {
      Issue.record("Expected platform plans for both automatic requests")
      return
    }
    #expect(stereoPlan.format.channels == .stereo)
    #expect(monoPlan.format.channels == .mono)
  }

  @Test
  func `exact source resolution produces one complete platform plan`() {
    let input = AudioInputSelection(id: "mic", name: "Microphone", channelCount: .stereo)
    let source = AudioSourceSelection(
      id: "front",
      name: "Front",
      polarPatternID: "stereo",
      polarPatternName: "Stereo",
    )
    let capabilities = snapshot(
      input: input,
      options: [
        AudioSourceConfigurationOption(inputID: input.id, source: source, channels: .stereo)
      ],
      applied: nil,
    ).capabilities
    let request = AudioInputConfigurationRequest(
      input: .specific(id: input.id),
      source: .specific(sourceID: source.id, polarPatternID: source.polarPatternID),
      channels: .stereo,
      sampleRate: .exact(.dvd),
      processing: .measurement,
    )

    let resolution = AudioInputConfigurationResolver.resolve(
      requested: request,
      generation: 4,
      capabilities: capabilities,
      currentApplied: nil,
    )

    guard case .apply(let plan) = resolution else {
      Issue.record("Expected a complete platform plan, got \(resolution)")
      return
    }
    #expect(plan.requestedGeneration == 4)
    #expect(plan.preferredInput == input)
    #expect(plan.resolvedInput == input)
    #expect(plan.source == source)
    #expect(plan.format == InputConfiguration(sampleRate: .dvd, channels: .stereo))
    #expect(plan.processing == .measurement)
  }

  @Test
  func `explicit stereo remains unsupported on a mono-only input`() {
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    let resolution = AudioInputConfigurationResolver.resolve(
      requested: request,
      generation: 3,
      capabilities: monoSnapshot(appliedChannels: .mono).capabilities,
      currentApplied: monoSnapshot(appliedChannels: .mono).applied,
    )

    #expect(resolution == .unsupported(.unsupportedChannels(.stereo)))
    #expect(request.channels == .stereo)
  }

  @Test
  @MainActor
  func `platform no-op keeps stereo requested and reports mono readback`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: .mono))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    let state = await coordinator.submit(request, isRunning: true, isActive: true)

    #expect(state.requested.channels == .stereo)
    #expect(state.applied?.format.channels == .mono)
    guard case .unsatisfied(.readbackMismatch) = state.reconciliation else {
      Issue.record("Expected readback mismatch, got \(state.reconciliation)")
      return
    }
  }

  @Test
  @MainActor
  func `apply failure preserves stereo intent and publishes truthful mono readback`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(
      snapshot: stereoSnapshot(appliedChannels: .mono),
      throwsOnApply: true,
    )
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo

    let state = await coordinator.submit(request, isRunning: true, isActive: true)

    #expect(state.requested.channels == .stereo)
    #expect(state.applied?.format.channels == .mono)
    guard case .unsatisfied(.platformOperationFailed) = state.reconciliation else {
      Issue.record("Expected platform failure, got \(state.reconciliation)")
      return
    }
  }

  @Test
  @MainActor
  func `sample-rate rejection keeps requested rate and reports applied rate`() async throws {
    let defaults = try isolatedDefaults()
    let input = AudioInputSelection(id: "mic", name: "Mic", channelCount: .stereo)
    let adapter = ScriptedAdapter(
      snapshot: snapshot(
        input: input,
        options: [
          AudioSourceConfigurationOption(inputID: input.id, source: nil, channels: .stereo)
        ],
        applied: AppliedAudioInputConfiguration(
          input: input,
          source: nil,
          format: InputConfiguration(sampleRate: .cd, channels: .stereo),
          processing: .processed,
        ),
      )
    )
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo
    request.sampleRate = .exact(.dvd)

    let state = await coordinator.submit(request, isRunning: true, isActive: true)

    #expect(state.requested.sampleRate == .exact(.dvd))
    #expect(state.applied?.format.sampleRate == .cd)
    #expect(
      state.reconciliation == .unsatisfied(.rejectedSampleRate(requested: .dvd, applied: .cd)))
  }

  @Test
  @MainActor
  func `partial source readback cannot satisfy exact stereo source`() async throws {
    let defaults = try isolatedDefaults()
    let input = AudioInputSelection(id: "mic", name: "Mic", channelCount: .stereo)
    let requestedSource = AudioSourceSelection(
      id: "front",
      name: "Front",
      polarPatternID: "stereo",
      polarPatternName: "Stereo",
    )
    let appliedSource = AudioSourceSelection(
      id: "back",
      name: "Back",
      polarPatternID: "stereo",
      polarPatternName: "Stereo",
    )
    let adapter = ScriptedAdapter(
      snapshot: snapshot(
        input: input,
        options: [
          AudioSourceConfigurationOption(
            inputID: input.id,
            source: requestedSource,
            channels: .stereo,
          )
        ],
        applied: AppliedAudioInputConfiguration(
          input: input,
          source: appliedSource,
          format: InputConfiguration(sampleRate: .dvd, channels: .stereo),
          processing: .processed,
        ),
      )
    )
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.input = .specific(id: input.id)
    request.source = .specific(sourceID: requestedSource.id, polarPatternID: "stereo")
    request.channels = .stereo

    let state = await coordinator.submit(request, isRunning: true, isActive: true)

    #expect(state.requested.source == request.source)
    guard case .unsatisfied(.readbackMismatch) = state.reconciliation else {
      Issue.record("Expected source readback mismatch, got \(state.reconciliation)")
      return
    }
  }

  @Test
  func `resolver rejects an unsupported exact polar pattern`() {
    let input = AudioInputSelection(id: "mic", name: "Mic", channelCount: .stereo)
    let source = AudioSourceSelection(
      id: "front",
      name: "Front",
      polarPatternID: "cardioid",
      polarPatternName: "Cardioid",
    )
    var request = AudioInputConfigurationRequest.automatic
    request.source = .specific(sourceID: source.id, polarPatternID: "stereo")

    let resolution = AudioInputConfigurationResolver.resolve(
      requested: request,
      generation: 9,
      capabilities: snapshot(
        input: input,
        options: [
          AudioSourceConfigurationOption(inputID: input.id, source: source, channels: .mono)
        ],
        applied: nil,
      ).capabilities,
      currentApplied: nil,
    )

    #expect(resolution == .unsupported(.unsupportedPolarPattern(id: "stereo")))
  }

  @Test
  @MainActor
  func `route refresh changes capabilities without erasing stereo request`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: .stereo))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo
    _ = await coordinator.submit(request, isRunning: true, isActive: true)

    await adapter.setSnapshot(monoSnapshot(appliedChannels: .mono))
    let state = await coordinator.reconcile(isRunning: true, isActive: true)

    #expect(state.requested.channels == .stereo)
    #expect(state.capabilities.effectiveInput?.channelCount == .mono)
    #expect(state.reconciliation == .unsatisfied(.unsupportedChannels(.stereo)))
  }

  @Test
  @MainActor
  func `deactivation clears applied state without changing request`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: .stereo))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo
    _ = await coordinator.submit(request, isRunning: true, isActive: true)

    let state = coordinator.markUnavailable(.sessionInactive)

    #expect(state.requested.channels == .stereo)
    #expect(state.applied == nil)
    #expect(state.reconciliation == .deferred(.sessionInactive))
  }

  @Test
  @MainActor
  func `media-services recovery reconciles the unchanged latest generation`() async throws {
    let defaults = try isolatedDefaults()
    let adapter = ScriptedAdapter(snapshot: stereoSnapshot(appliedChannels: .stereo))
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var request = AudioInputConfigurationRequest.automatic
    request.channels = .stereo
    let applied = await coordinator.submit(request, isRunning: true, isActive: true)

    let unavailable = coordinator.markUnavailable(.mediaServicesUnavailable)
    let recovered = await coordinator.reconcile(isRunning: true, isActive: true)

    #expect(unavailable.requested == request)
    #expect(unavailable.requestedGeneration == applied.requestedGeneration)
    #expect(unavailable.applied == nil)
    #expect(unavailable.reconciliation == .deferred(.mediaServicesUnavailable))
    #expect(recovered.requested == request)
    #expect(recovered.requestedGeneration == applied.requestedGeneration)
    #expect(recovered.applied?.format.channels == .stereo)
    #expect(recovered.reconciliation == .satisfied)
  }

  @Test
  @MainActor
  func `newer request wins over an in-flight uninterruptible apply`() async throws {
    let defaults = try isolatedDefaults()
    let input = AudioInputSelection(id: "mic", name: "Mic", channelCount: .stereo)
    let adapter = BlockingAdapter(input: input)
    let coordinator = AudioInputConfigurationCoordinator(defaults: defaults, adapter: adapter)
    var stereo = AudioInputConfigurationRequest.automatic
    stereo.channels = .stereo
    let first = MainActorOwnedWork {
      _ = await coordinator.submit(stereo, isRunning: true, isActive: true)
    }
    await adapter.waitForFirstApply()

    var mono = AudioInputConfigurationRequest.automatic
    mono.channels = .mono
    let second = MainActorOwnedWork {
      _ = await coordinator.submit(mono, isRunning: true, isActive: true)
    }
    await second.value
    await adapter.release()
    await first.value

    #expect(coordinator.state.requested.channels == .mono)
    #expect(coordinator.state.applied?.format.channels == .mono)
    #expect(coordinator.state.reconciliation == .satisfied)
  }

  @Test
  func `resolver rejects an exact unsupported source without changing channel intent`() {
    var request = AudioInputConfigurationRequest.automatic
    request.source = .specific(sourceID: "missing", polarPatternID: nil)
    request.channels = .stereo

    let decision = AudioInputConfigurationResolver.resolve(
      requested: request,
      generation: 7,
      capabilities: stereoSnapshot(appliedChannels: nil).capabilities,
      currentApplied: nil,
    )

    #expect(decision == .unsupported(.unsupportedSource(id: "missing")))
    #expect(request.channels == .stereo)
  }

  @Test
  @MainActor
  func `legacy preference keys are ignored`() throws {
    let defaults = try isolatedDefaults()
    defaults.set("old-mic", forKey: "aio.audio_env.explicit_preferred_input_id.v2")
    defaults.set(true, forKey: "aio.audio_env.use_measurement")
    defaults.set(Data([0x00]), forKey: "aio.audio_env.input_prefs_by_id.v1")

    let store = AudioInputConfigurationRequestStore(defaults: defaults)

    #expect(store.load() == .automatic)
  }

  @Test
  @MainActor
  func `complete request schema round trips`() throws {
    let defaults = try isolatedDefaults()
    let store = AudioInputConfigurationRequestStore(defaults: defaults)
    let request = AudioInputConfigurationRequest(
      input: .specific(id: "usb"),
      source: .specific(sourceID: "front", polarPatternID: "stereo"),
      channels: .stereo,
      sampleRate: .exact(.hiRes96),
      processing: .measurement,
    )

    store.save(request)

    #expect(store.load() == request)
  }

  private func stereoSnapshot(
    appliedChannels: ChannelCount?,
  ) -> PlatformAudioInputSnapshot {
    let input = AudioInputSelection(
      id: "mic",
      name: "Stereo Microphone",
      channelCount: .stereo,
    )
    let mono = AudioSourceConfigurationOption(
      inputID: input.id,
      source: nil,
      channels: .mono,
    )
    let stereo = AudioSourceConfigurationOption(
      inputID: input.id,
      source: nil,
      channels: .stereo,
    )
    return PlatformAudioInputSnapshot(
      capabilities: AudioInputConfigurationCapabilities(
        discovery: .resolved,
        inputs: [input],
        effectiveInput: input,
        sourceOptions: [mono, stereo],
        likelySampleRates: [.dvd],
      ),
      applied: appliedChannels.map {
        AppliedAudioInputConfiguration(
          input: input,
          source: nil,
          format: InputConfiguration(sampleRate: .dvd, channels: $0),
          processing: .processed,
        )
      },
    )
  }

  private func monoSnapshot(
    appliedChannels: ChannelCount?,
  ) -> PlatformAudioInputSnapshot {
    let input = AudioInputSelection(
      id: "mic",
      name: "Mono Microphone",
      channelCount: .mono,
    )
    return snapshot(
      input: input,
      options: [
        AudioSourceConfigurationOption(inputID: input.id, source: nil, channels: .mono)
      ],
      applied: appliedChannels.map {
        AppliedAudioInputConfiguration(
          input: input,
          source: nil,
          format: InputConfiguration(sampleRate: .dvd, channels: $0),
          processing: .processed,
        )
      },
    )
  }

  private func snapshot(
    input: AudioInputSelection,
    options: [AudioSourceConfigurationOption],
    applied: AppliedAudioInputConfiguration?,
  ) -> PlatformAudioInputSnapshot {
    PlatformAudioInputSnapshot(
      capabilities: AudioInputConfigurationCapabilities(
        discovery: .resolved,
        inputs: [input],
        effectiveInput: input,
        sourceOptions: options,
        likelySampleRates: [.cd, .dvd],
      ),
      applied: applied,
    )
  }

  @MainActor
  private func isolatedDefaults() throws -> UserDefaults {
    let name = "AudioInputConfigurationCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }
}
