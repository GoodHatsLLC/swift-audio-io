// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOSupport
  import AVFoundation

  /// Owns the `AVAudioEngine` input-tap lifecycle for microphone capture.
  ///
  /// The tap itself is installed during graph preparation. This backend gives
  /// microphone capture the same start/stop/cleanup boundary as every other
  /// source, so the recording coordinator never infers a source from the
  /// presence or absence of a backend.
  // SAFETY: graph mutations are serialized by `AIOEngine.engineControlQueue`;
  // lifecycle entry points are either synchronous off-main start or MainActor
  // stop/cleanup.
  @safe final class MicrophoneCaptureBackend: RecordingCaptureBackend, @unchecked Sendable {
    private weak var owner: AIOEngine?

    init(owner: AIOEngine) {
      self.owner = owner
    }

    func start() throws(RecordingError) {
      guard let owner else {
        throw RecordingError.engineError
      }
      let result = owner.runOnEngineControlQueueResult {
        try AudioSessionAccess.throwing {
          try owner.engine.start()
        }
      }
      if case .failure(let error) = result {
        throw RecordingError.session(.engineStartFailed(error: ErrorContext(error)))
      }
    }

    @MainActor
    func stop(mode: RecordingCaptureStopMode) {
      guard let owner else { return }

      if let teardown = owner.recordingEnvironment.engineTeardown {
        teardown()
        _ = owner.state.consume(\.installedTapBus)
        return
      }

      let tapBus = owner.state.consume(\.installedTapBus)
      let busesToRemove = Array(Set([tapBus, 0].compactMap(\.self)))
      owner.engineControlQueue.async { [weak owner] in
        guard let owner else { return }
        dispatchPrecondition(condition: .onQueue(owner.engineControlQueue))
        for bus in busesToRemove {
          owner.engine.inputNode.removeTap(onBus: bus)
        }
        if owner.engine.isRunning {
          owner.engine.stop()
        }
        guard mode == .immediate else { return }
        if owner.player.isPlaying {
          owner.player.stop()
        }
        owner.engine.reset()
      }
    }

    @MainActor
    func cleanup() {}
  }
#endif
