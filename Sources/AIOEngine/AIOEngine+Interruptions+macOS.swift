#if os(macOS)
  extension AIOEngine {
    @MainActor
    public func handleRouteChange(event: AudioRouteChangeEvent) async {
      _ = event
    }

    @MainActor
    public func handleInterruption(
      type: AudioInterruptionType,
      options: AudioInterruptionOptions?
    ) async {
      _ = type
      _ = options
    }

    @MainActor
    public func handleMediaServicesLost() async {}

    @MainActor
    public func handleMediaServicesReset() async {}
  }
#endif
