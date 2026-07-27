// © GoodHatsLLC

#if os(macOS)
  import Foundation
  import Testing
  @testable import AIOAudioSession
  @testable import AudioIO
  import Tools

  struct PlatformAudioBackendContractTests {
    // SAFETY: Test backend state is guarded by `lock`; the signals are
    // Sendable synchronization primitives.
    final class StubState: @unchecked Sendable {
      private let lock = NSLock()
      private var inputs: [PlatformAudioInputDescriptor]
      private let routeSignal = AsyncSignal<PlatformAudioRouteEvent>()
      private let subscriberReady = AsyncContinuation<Void>()

      init(inputs: [PlatformAudioInputDescriptor]) {
        self.inputs = inputs
      }

      func routeChanges() -> AsyncSignalStream<PlatformAudioRouteEvent> {
        try? subscriberReady.yield()
        return routeSignal.events()
      }

      func waitForSubscriber() async {
        await subscriberReady()
      }

      func currentInputs() -> [PlatformAudioInputDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return inputs
      }

      func updateInputs(_ inputs: [PlatformAudioInputDescriptor]) {
        lock.lock()
        self.inputs = inputs
        lock.unlock()
      }

      func emitRouteChange() {
        routeSignal.yield(.changed)
      }
    }

    struct StubPlatformAudioBackend: PlatformAudioBackend {
      let state: StubState
      let platformName = "stub"

      func routeChanges() -> AsyncSignalStream<PlatformAudioRouteEvent> {
        state.routeChanges()
      }

      func availableInputs() async -> [PlatformAudioInputDescriptor] {
        state.currentInputs()
      }
    }

    @Test
    @MainActor
    func `run discovers the system default without converting it to explicit intent`() async throws
    {
      let state = StubState(inputs: [monoInput(isDefault: false), stereoInput(isDefault: true)])
      let manager = try manager(state: state)

      let runTask = MainActorOwnedWork { try? await manager.run() }
      await state.waitForSubscriber()

      #expect(manager.isReady)
      #expect(manager.inputConfigurationState.requested.input == .systemDefault)
      #expect(manager.inputConfigurationState.capabilities.inputs.count == 2)
      #expect(manager.inputConfigurationState.capabilities.effectiveInput?.id == "mic-b")
      #expect(manager.inputConfigurationState.reconciliation == .deferred(.sessionInactive))

      await runTask.cancel()
    }

    @Test
    @MainActor
    func `activation applies automatic stereo through the common settle barrier`() async throws {
      let state = StubState(inputs: [stereoInput(isDefault: true)])
      let manager = try manager(state: state)
      let runTask = MainActorOwnedWork { try? await manager.run() }
      await state.waitForSubscriber()

      try await manager.setAudioSessionActive(true)
      let settled = try await manager.settleInputConfiguration()

      #expect(settled.format.channels == .stereo)
      #expect(settled.preferredInput == nil)
      #expect(manager.inputConfigurationState.reconciliation == .satisfied)

      await runTask.cancel()
    }

    @Test
    @MainActor
    func `settle returns only the latest satisfied request generation`() async throws {
      let state = StubState(inputs: [stereoInput(isDefault: true)])
      let manager = try manager(state: state)
      let runTask = MainActorOwnedWork { try? await manager.run() }
      await state.waitForSubscriber()
      try await manager.setAudioSessionActive(true)

      var stereo = manager.inputConfigurationState.requested
      stereo.channels = .stereo
      let first = await manager.requestInputConfiguration(stereo)
      var mono = stereo
      mono.channels = .mono
      let latest = await manager.requestInputConfiguration(mono)

      let settled = try await manager.settleInputConfiguration()

      #expect(latest.requestedGeneration > first.requestedGeneration)
      #expect(settled.requestGeneration == latest.requestedGeneration)
      #expect(settled.format.channels == .mono)
      #expect(manager.inputConfigurationState.reconciliation == .satisfied)

      await runTask.cancel()
    }

    @Test
    @MainActor
    func `explicit input request survives disappearance and reattaches on return`() async throws {
      let micA = monoInput()
      let micB = stereoInput(isDefault: false)
      let state = StubState(inputs: [micA, micB])
      let manager = try manager(state: state)
      let runTask = MainActorOwnedWork { try? await manager.run() }
      await state.waitForSubscriber()
      try await manager.setAudioSessionActive(true)

      var request = manager.inputConfigurationState.requested
      request.input = .specific(id: micB.id)
      request.channels = .stereo
      _ = await manager.requestInputConfiguration(request)
      #expect(manager.inputConfigurationState.reconciliation == .satisfied)

      state.updateInputs([micA])
      await emitRouteChangeAndAwaitRefresh(state: state, manager: manager)
      #expect(manager.inputConfigurationState.requested.input == .specific(id: micB.id))
      #expect(
        manager.inputConfigurationState.reconciliation
          == .deferred(.requestedInputUnavailable(id: micB.id)),
      )

      state.updateInputs([micA, micB])
      await emitRouteChangeAndAwaitRefresh(state: state, manager: manager)
      #expect(manager.inputConfigurationState.reconciliation == .satisfied)
      #expect(manager.inputConfigurationState.applied?.input.id == micB.id)

      await runTask.cancel()
    }

    @Test
    @MainActor
    func `route change refreshes capabilities without changing requested channels`() async throws {
      let state = StubState(inputs: [monoInput()])
      let manager = try manager(state: state)
      let runTask = MainActorOwnedWork { try? await manager.run() }
      await state.waitForSubscriber()
      var request = manager.inputConfigurationState.requested
      request.channels = .stereo
      _ = await manager.requestInputConfiguration(request)

      state.updateInputs([stereoInput(isDefault: true)])
      await emitRouteChangeAndAwaitRefresh(state: state, manager: manager)

      #expect(manager.inputConfigurationState.requested.channels == .stereo)
      #expect(manager.inputConfigurationState.capabilities.effectiveInput?.channelCount == .stereo)

      await runTask.cancel()
    }

    @MainActor
    private func manager(state: StubState) throws -> AudioEnvironmentManager {
      let suiteName = "aio.tests.platform-backend.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defaults.removePersistentDomain(forName: suiteName)
      return AudioEnvironmentManager(
        env: AudioEnvironment(),
        errorManager: MockErrorManager(),
        defaults: defaults,
        platformAudioBackend: StubPlatformAudioBackend(state: state),
      )
    }

    private func monoInput(isDefault: Bool = true) -> PlatformAudioInputDescriptor {
      PlatformAudioInputDescriptor(
        id: "mic-a",
        name: "Built-in Microphone",
        channelCount: 1,
        isDefault: isDefault,
      )
    }

    private func stereoInput(isDefault: Bool) -> PlatformAudioInputDescriptor {
      PlatformAudioInputDescriptor(
        id: "mic-b",
        name: "USB Microphone",
        type: .usbAudio,
        channelCount: 2,
        isDefault: isDefault,
      )
    }

    @MainActor
    private func emitRouteChangeAndAwaitRefresh(
      state: StubState,
      manager: AudioEnvironmentManager,
    ) async {
      let refreshed = AsyncContinuation<Void>()
      let subscriberID = manager.addAudioSystemEventSubscriber { event in
        if case .routeChanged = event {
          try? refreshed.yield()
        }
      }
      state.emitRouteChange()
      await refreshed()
      manager.removeSubscriber(subscriberID)
    }
  }
#endif
