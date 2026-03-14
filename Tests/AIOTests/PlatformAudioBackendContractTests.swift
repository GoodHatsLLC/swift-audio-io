// © GoodHatsLLC

#if os(macOS)
  import Foundation
  import Testing
  @testable import AIOEngine

  struct PlatformAudioBackendContractTests {
    actor StubState {
      private var inputs: [PlatformAudioInputDescriptor]
      private var continuation: AsyncStream<PlatformAudioRouteEvent>.Continuation?

      init(inputs: [PlatformAudioInputDescriptor]) {
        self.inputs = inputs
      }

      func setContinuation(_ continuation: AsyncStream<PlatformAudioRouteEvent>.Continuation) {
        self.continuation = continuation
      }

      func currentInputs() -> [PlatformAudioInputDescriptor] {
        inputs
      }

      func updateInputs(_ inputs: [PlatformAudioInputDescriptor]) {
        self.inputs = inputs
      }

      func emitRouteChange() {
        continuation?.yield(.changed)
      }

      func hasSubscriber() -> Bool {
        continuation != nil
      }
    }

    struct StubPlatformAudioBackend: PlatformAudioBackend {
      let state: StubState

      let platformName: String = "stub"

      func routeChanges() -> AsyncStream<PlatformAudioRouteEvent> {
        AsyncStream { continuation in
          Task {
            await state.setContinuation(continuation)
          }
        }
      }

      func availableInputs() async -> [PlatformAudioInputDescriptor] {
        await state.currentInputs()
      }
    }

    @MainActor
    private func makeIsolatedDefaults() throws -> UserDefaults {
      let suiteName = "aio.tests.platform-backend.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suiteName))
      defaults.removePersistentDomain(forName: suiteName)
      return defaults
    }

    @MainActor
    private func waitUntil(
      timeoutMillis: Int = 2000,
      _ predicate: @escaping @MainActor () async -> Bool,
    ) async -> Bool {
      let deadline = Date().addingTimeInterval(Double(timeoutMillis) / 1000.0)
      while Date() < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(20))
      }
      return await predicate()
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

      let runTask = Task { @MainActor in
        try await manager.run()
      }

      let becameReady = await waitUntil {
        manager.isReady
      }

      #expect(becameReady)
      #expect(manager.availableInputs.count == 2)
      #expect(manager.selectedInput?.id == "mic-b")
      #expect(manager.selectedInput?.channelCount == .stereo)

      runTask.cancel()
      _ = await runTask.result
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

      let runTask = Task { @MainActor in
        try await manager.run()
      }

      let becameReady = await waitUntil {
        manager.isReady
      }
      #expect(becameReady)

      let subscribed = await waitUntil {
        await state.hasSubscriber()
      }
      #expect(subscribed)

      await state.updateInputs(
        [
          PlatformAudioInputDescriptor(
            id: "mic-b",
            name: "USB Mic",
            channelCount: 2,
            isDefault: true,
          )
        ],
      )
      await state.emitRouteChange()

      let refreshed = await waitUntil {
        manager.selectedInput?.id == "mic-b"
      }
      #expect(refreshed)
      #expect(manager.availableInputs.count == 1)
      #expect(manager.selectedInput?.channelCount == .stereo)

      runTask.cancel()
      _ = await runTask.result
    }
  }
#endif
