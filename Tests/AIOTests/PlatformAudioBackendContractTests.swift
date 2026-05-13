// © GoodHatsLLC

#if os(macOS)
  import Foundation
  import Testing
  @testable import AIOAudioSession
  @testable import AIOEngine
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
    func `run loads available inputs and selects default input`() async throws {
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
      #expect(manager.selectedInput?.id == "mic-b")
      #expect(manager.selectedInput?.channelCount == .stereo)

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
            channelCount: 2,
            isDefault: true,
          )
        ],
      )
      state.emitRouteChange()
      await refreshed()
      manager.removeSubscriber(subscriberID)

      #expect(manager.availableInputs.count == 1)
      #expect(manager.selectedInput?.id == "mic-b")
      #expect(manager.selectedInput?.channelCount == .stereo)

      await runTask.cancel()
    }
  }
#endif
