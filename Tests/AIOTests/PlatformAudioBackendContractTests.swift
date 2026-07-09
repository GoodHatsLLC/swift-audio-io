// © GoodHatsLLC

#if os(macOS)
  import Foundation
  import Testing
  @testable import AIOAudioSession
  @testable import AudioIO
  import Tools

  struct PlatformAudioBackendContractTests {
    // SAFETY: Test backend state is guarded by `lock`; `routeSignal` and
    // `subscriberReady` are Sendable synchronization primitives.
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

      let platformName: String = "stub"

      func routeChanges() -> AsyncSignalStream<PlatformAudioRouteEvent> {
        state.routeChanges()
      }

      func availableInputs() async -> [PlatformAudioInputDescriptor] {
        state.currentInputs()
      }
    }

    @MainActor
    private func makeIsolatedDefaults() throws -> UserDefaults {
      let suiteName = "aio.tests.platform-backend.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defaults.removePersistentDomain(forName: suiteName)
      return defaults
    }

    @Test
    @MainActor
    func `run loads available inputs and follows the system default without pinning`() async throws
    {
      let initialInputs = [
        PlatformAudioInputDescriptor(
          id: "mic-a",
          name: "Built-in Microphone",
          channelCount: 1,
          isDefault: false,
        ),
        PlatformAudioInputDescriptor(
          id: "mic-b",
          name: "USB Mic",
          type: .usbAudio,
          channelCount: 2,
          isDefault: true,
        ),
      ]
      let state = StubState(inputs: initialInputs)
      let backend = StubPlatformAudioBackend(state: state)
      let manager = try AudioEnvironmentManager(
        env: AudioEnvironment(),
        errorManager: MockErrorManager(),
        defaults: makeIsolatedDefaults(),
        platformAudioBackend: backend,
      )

      let runTask = MainActorOwnedWork {
        try? await manager.run()
      }

      await state.waitForSubscriber()

      #expect(manager.isReady)
      #expect(manager.availableInputs.count == 2)
      // No explicit selection: `selectedInput` stays nil ("follow the system
      // default") so recordings never pin a concrete device the user didn't
      // choose. Capability state still derives from the default input.
      #expect(manager.selectedInput == nil)
      #expect(manager.preferredInput == nil)
      #expect(manager.inputHasStereoSource)

      await runTask.cancel()
    }

    @Test
    @MainActor
    func `route changes refresh available inputs`() async throws {
      let state = StubState(
        inputs: [
          PlatformAudioInputDescriptor(
            id: "mic-a",
            name: "Built-in Microphone",
            channelCount: 1,
            isDefault: true,
          )
        ],
      )
      let backend = StubPlatformAudioBackend(state: state)
      let manager = try AudioEnvironmentManager(
        env: AudioEnvironment(),
        errorManager: MockErrorManager(),
        defaults: makeIsolatedDefaults(),
        platformAudioBackend: backend,
      )

      let runTask = MainActorOwnedWork {
        try? await manager.run()
      }

      await state.waitForSubscriber()
      #expect(manager.isReady)

      let refreshed = AsyncContinuation<Void>()
      let subscriberID = manager.addRouteChangeSubscriber { _ in
        try? refreshed.yield()
      }

      state.updateInputs(
        [
          PlatformAudioInputDescriptor(
            id: "mic-b",
            name: "USB Mic",
            type: .usbAudio,
            channelCount: 2,
            isDefault: true,
          )
        ],
      )
      state.emitRouteChange()
      await refreshed()
      manager.removeSubscriber(subscriberID)

      #expect(manager.availableInputs.count == 1)
      // Still no explicit selection after the refresh: the manager keeps
      // following the system default instead of pinning the new device.
      #expect(manager.selectedInput == nil)
      #expect(manager.inputHasStereoSource)

      await runTask.cancel()
    }

    @Test
    @MainActor
    func `explicit selection survives route refreshes`() async throws {
      let micA = PlatformAudioInputDescriptor(
        id: "mic-a",
        name: "Built-in Microphone",
        channelCount: 1,
        isDefault: true,
      )
      let micB = PlatformAudioInputDescriptor(
        id: "mic-b",
        name: "USB Mic",
        type: .usbAudio,
        channelCount: 2,
        isDefault: false,
      )
      let state = StubState(inputs: [micA, micB])
      let backend = StubPlatformAudioBackend(state: state)
      let manager = try AudioEnvironmentManager(
        env: AudioEnvironment(),
        errorManager: MockErrorManager(),
        defaults: makeIsolatedDefaults(),
        platformAudioBackend: backend,
      )

      let runTask = MainActorOwnedWork {
        try? await manager.run()
      }
      await state.waitForSubscriber()

      let explicit = try #require(manager.availableInputs.first(where: { $0.id == "mic-b" }))
      manager.selectedInput = explicit
      #expect(manager.selectedInput?.id == "mic-b")

      await emitRouteChangeAndAwaitRefresh(state: state, manager: manager)

      #expect(manager.selectedInput?.id == "mic-b")
      #expect(manager.preferredInput?.id == "mic-b")

      await runTask.cancel()
    }

    @Test
    @MainActor
    func `explicit selection falls back to default when absent and re-attaches on return`()
      async throws
    {
      let micA = PlatformAudioInputDescriptor(
        id: "mic-a",
        name: "Built-in Microphone",
        channelCount: 1,
        isDefault: true,
      )
      let micB = PlatformAudioInputDescriptor(
        id: "mic-b",
        name: "USB Mic",
        type: .usbAudio,
        channelCount: 2,
        isDefault: false,
      )
      let state = StubState(inputs: [micA, micB])
      let backend = StubPlatformAudioBackend(state: state)
      let manager = try AudioEnvironmentManager(
        env: AudioEnvironment(),
        errorManager: MockErrorManager(),
        defaults: makeIsolatedDefaults(),
        platformAudioBackend: backend,
      )

      let runTask = MainActorOwnedWork {
        try? await manager.run()
      }
      await state.waitForSubscriber()

      let explicit = try #require(manager.availableInputs.first(where: { $0.id == "mic-b" }))
      manager.selectedInput = explicit

      // The explicitly selected device disappears: fall back to the system
      // default (nil) rather than pinning some other remaining device.
      state.updateInputs([micA])
      await emitRouteChangeAndAwaitRefresh(state: state, manager: manager)
      #expect(manager.selectedInput == nil)
      #expect(manager.preferredInput == nil)

      // The device returns: the explicit selection re-attaches.
      state.updateInputs([micA, micB])
      await emitRouteChangeAndAwaitRefresh(state: state, manager: manager)
      #expect(manager.selectedInput?.id == "mic-b")

      await runTask.cancel()
    }

    /// Emits a stub route change and waits until the manager has refreshed its
    /// inputs (route subscribers are notified after the refresh completes).
    @MainActor
    private func emitRouteChangeAndAwaitRefresh(
      state: StubState,
      manager: AudioEnvironmentManager,
    ) async {
      let refreshed = AsyncContinuation<Void>()
      let subscriberID = manager.addRouteChangeSubscriber { _ in
        try? refreshed.yield()
      }
      state.emitRouteChange()
      await refreshed()
      manager.removeSubscriber(subscriberID)
    }
  }
#endif
