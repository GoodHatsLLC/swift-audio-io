// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOAudioSession
  import AIOSupport
  package import AIOEngineCore
  package import AIORecordingSupport
  import Atomics
  package import AVFoundation
  import os
  import Tools

  private let tapSetupLog = SystemLog.make()

  extension AIOEngine {
    nonisolated func makeTapConversionArtifacts(
      inputFormat: AVAudioFormat,
      processingFormat: AVAudioFormat,
      tapBufferSize: AVAudioFrameCount,
    ) throws(RecordingError) -> TapConversionArtifacts {
      guard let converter = AVAudioConverter(from: inputFormat, to: processingFormat) else {
        throw RecordingError.formatConversionFailed
      }
      let tapFrameRatio = processingFormat.sampleRate / inputFormat.sampleRate
      let maxTapFrames = max(
        AVAudioFrameCount(ceil(Double(tapBufferSize) * tapFrameRatio)),
        1,
      )
      guard
        let convertedBuffer = AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: maxTapFrames,
        )
      else {
        throw RecordingError.formatConversionFailed
      }
      return TapConversionArtifacts(
        converter: converter,
        inputFormat: inputFormat,
        convertedBuffer: convertedBuffer,
      )
    }

    /// Reinstalls the audio input tap on the engine.
    ///
    /// This is the single method used by `warm()`, route change handling,
    /// and tap interval updates. All engine graph mutations happen on the
    /// engine control queue in a single dispatch.
    #if DEBUG
      /// Resolves the `@MainActor` test tap-install override (if any) on the main
      /// actor, returning its transferable result so the nonisolated warm path can
      /// honour the seam without invoking a `@MainActor` closure off-main.
      @MainActor
      func resolveReinstallTapOverrideResult(
        configuration: RecordingConfiguration,
        processingFormat: AVAudioFormat,
      ) -> Transferring<Result<TapInstallResult, RecordingError>>? {
        guard let override = testReinstallTapOverride else { return nil }
        let result: Result<TapInstallResult, RecordingError>
        do {
          result = .success(try override(configuration, processingFormat))
        } catch {
          result = .failure(error)
        }
        return Transferring(result)
      }
    #endif

    /// Builds the `overrideResult` argument for ``reinstallTap`` from the
    /// `@MainActor` test seam. Returns `nil` in release builds (the seam only
    /// exists under `#if DEBUG`). Every `@MainActor` caller of ``reinstallTap``
    /// (warm path, both route-change handlers, and tap-interval changes) routes
    /// through this single helper so none of them bypass the seam.
    @MainActor
    package func reinstallTapOverrideResult(
      configuration: RecordingConfiguration,
      processingFormat: AVAudioFormat,
    ) -> Transferring<Result<TapInstallResult, RecordingError>>? {
      #if DEBUG
        return resolveReinstallTapOverrideResult(
          configuration: configuration,
          processingFormat: processingFormat,
        )
      #else
        return nil
      #endif
    }

    /// Reinstalls the input tap **synchronously** on the engine-control queue.
    ///
    /// Used by the off-main `performWarm` (and the public, intentionally-sync
    /// `warm()`), where the caller is already off the main thread or has opted
    /// into a blocking call. `@MainActor` lifecycle handlers must use the async
    /// ``reinstallTapAsync(configuration:processingFormat:stopEngine:overrideResult:)``
    /// instead so they never block the main thread.
    ///
    /// Returns `nil` — **without mutating the graph** — when a teardown
    /// (`gracefulStop()` / `hardStop()`) has set ``AIOEngine/engineTearingDown``
    /// before this reinstall reached the head of the serial queue. See
    /// ``reinstallTapOnEngineControlQueue(configuration:processingFormat:stopEngine:overrideResult:)``.
    package nonisolated func reinstallTap(
      configuration: RecordingConfiguration,
      processingFormat: AVAudioFormat,
      stopEngine: Bool,
      overrideResult: Transferring<Result<TapInstallResult, RecordingError>>? = nil,
    ) throws(RecordingError) -> TapInstallResult? {
      let installResult = runOnEngineControlQueueResult {
        [weak self] () throws -> TapInstallResult? in
        guard let self else { throw RecordingError.engineError }
        return try self.reinstallTapOnEngineControlQueue(
          configuration: configuration,
          processingFormat: processingFormat,
          stopEngine: stopEngine,
          overrideResult: overrideResult,
        )
      }
      return try finishReinstall(installResult)
    }

    /// Reinstalls the input tap **without blocking the main thread**, dispatching
    /// the graph mutation onto the engine-control queue via the async
    /// `withEngineControlQueueResult` helper.
    ///
    /// `@MainActor` callers (route-change handlers, tap-interval reconfigure)
    /// `await` this and **must** re-check liveness after the await — both
    /// `guard isRecording` and `guard !engineTearingDown` — before applying the
    /// result or emitting events, because a stop can complete (or begin) while
    /// the reinstall is suspended. The on-queue teardown guard inside the shared
    /// body closes the in-queue race; the post-await re-check closes the tail
    /// where the reinstall ran on-queue *before* a teardown raised the sentinel.
    package nonisolated func reinstallTapAsync(
      configuration: RecordingConfiguration,
      processingFormat: AVAudioFormat,
      stopEngine: Bool,
      overrideResult: Transferring<Result<TapInstallResult, RecordingError>>? = nil,
    ) async throws(RecordingError) -> TapInstallResult? {
      let installResult = await withEngineControlQueueResult {
        [weak self] () throws -> TapInstallResult? in
        guard let self else { throw RecordingError.engineError }
        return try self.reinstallTapOnEngineControlQueue(
          configuration: configuration,
          processingFormat: processingFormat,
          stopEngine: stopEngine,
          overrideResult: overrideResult,
        )
      }
      return try finishReinstall(installResult)
    }

    /// Maps the engine-control-queue result of a reinstall into the
    /// `throws(RecordingError) -> TapInstallResult?` contract shared by the sync
    /// and async wrappers.
    private nonisolated func finishReinstall(
      _ installResult: Result<TapInstallResult?, any Error>,
    ) throws(RecordingError) -> TapInstallResult? {
      switch installResult {
      case .success(let result):
        if let result {
          tapSetupLog.info("Tap installed: \(result.tapFormat, privacy: .public)")
        }
        return result
      case .failure(let error):
        throw (error as? RecordingError) ?? .session(.engineStartFailed(error: ErrorContext(error)))
      }
    }

    /// The shared on-engine-control-queue tap-reinstall body, invoked by both the
    /// sync ``reinstallTap`` and async ``reinstallTapAsync`` wrappers. **Must run
    /// on the engine-control queue** (asserted below).
    ///
    /// Returns `nil` — **without mutating the graph** — when a teardown
    /// (`gracefulStop()` / `hardStop()`) has set ``AIOEngine/engineTearingDown``
    /// before this reinstall reached the head of the serial queue. The check is
    /// honoured **on the engine-control queue** (the only point serialized
    /// against the teardown's enqueued work), so a route-change / tap-interval
    /// reinstall that lost the race to a concurrent stop never reinstalls a live
    /// tap onto a torn-down/stopped graph. Callers treat `nil` as "the teardown
    /// owns the graph now; do nothing" — no event, no state resurrection.
    nonisolated func reinstallTapOnEngineControlQueue(
      configuration: RecordingConfiguration,
      processingFormat: AVAudioFormat,
      stopEngine: Bool,
      overrideResult: Transferring<Result<TapInstallResult, RecordingError>>?,
    ) throws -> TapInstallResult? {
      dispatchPrecondition(condition: .onQueue(engineControlQueue))

      // 0. Teardown serialization guard. If a teardown superseded this
      //    reinstall (it set `engineTearingDown` before enqueuing its teardown,
      //    which the FIFO serial queue ran ahead of us), bail before touching
      //    the graph. Checked here — on the serial queue — because
      //    `gracefulStop` flips `isRecording` only *after* its drain `await`, so
      //    a main-actor pre-check cannot close this window. The override seam is
      //    resolved *after* this guard so tests can exercise it deterministically
      //    without a real `AVAudioEngine`.
      if engineTearingDown.load(ordering: .sequentiallyConsistent) {
        tapSetupLog.info(
          "reinstallTap superseded by in-flight engine teardown; skipping graph mutation",
        )
        return nil
      }

      #if DEBUG
        if let overrideResult {
          switch overrideResult.value {
          case .success(let result): return result
          case .failure(let error): throw error
          }
        }
      #else
        _ = overrideResult
      #endif

      // 1. Remove existing tap
      let previousBus = state[locked: \.installedTapBus] ?? 0
      unsafe engine.inputNode.removeTap(onBus: previousBus)
      state[locked: \.installedTapBus] = nil

      // 2. Stop and reset engine if requested — reset() clears cached node
      //    formats so that prepare() queries the current hardware (critical
      //    after a route change where the sample rate may differ).
      if stopEngine {
        unsafe engine.stop()
        unsafe engine.reset()
        if unsafe !engine.attachedNodes.contains(player) {
          unsafe engine.attach(player)
        }
      }

      // 3. Prepare — updates input node for current hardware
      unsafe engine.prepare()

      // 4. Read format — one read, one validation
      let inputFormat = unsafe engine.inputNode.inputFormat(forBus: 0)
      guard inputFormat.channelCount > 0 else {
        throw RecordingError.session(
          .notReady(details: "Input node has no channels (channelCount: 0)"),
        )
      }
      guard inputFormat.sampleRate > 0 else {
        throw RecordingError.session(
          .notReady(details: "Input node has invalid sample rate (sampleRate: 0)"),
        )
      }

      // 5. Create tap configuration
      guard let tapConfig = configuration.tapConfiguration(bus: 0, input: inputFormat) else {
        throw RecordingError.invalidConfiguration(details: "Cannot create tap configuration")
      }
      guard tapConfig.bufferSize > 0 else {
        throw RecordingError.invalidConfiguration(details: "Tap bufferSize is 0")
      }

      // 6. Install tap with format: nil to match the node's current format
      unsafe engine.inputNode.installTap(
        onBus: tapConfig.bus,
        bufferSize: tapConfig.bufferSize,
        format: inputFormat,
        block: { @Sendable [self] buffer, time in
          self.processAudio(
            buffer: buffer,
            time: time,
            to: processingFormat,
          )
        },
      )

      // 7. Prepare post-install, read actual format
      unsafe engine.prepare()
      let postInstallFormat = unsafe engine.inputNode.inputFormat(forBus: 0)
      guard postInstallFormat.channelCount > 0, postInstallFormat.sampleRate > 0 else {
        throw RecordingError.invalidConfiguration(
          details:
            "Format invalid after tap install (channels: \(postInstallFormat.channelCount), sampleRate: \(postInstallFormat.sampleRate))",
        )
      }
      guard postInstallFormat.isEqual(inputFormat) else {
        throw RecordingError.invalidConfiguration(
          details:
            "Format changed after tap install (channels: \(inputFormat.channelCount), sampleRate: \(inputFormat.sampleRate)) -> (channels: \(postInstallFormat.channelCount), sampleRate: \(postInstallFormat.sampleRate))",
        )
      }

      // 8. Create conversion artifacts from the actual post-install format
      let artifacts = try makeTapConversionArtifacts(
        inputFormat: postInstallFormat,
        processingFormat: processingFormat,
        tapBufferSize: tapConfig.bufferSize,
      )

      let result = TapInstallResult(
        tapFormat: postInstallFormat,
        artifacts: artifacts,
        tapConfiguration: tapConfig,
      )

      // 9. Apply converter state before starting the engine so that
      //    processAudio sees the correct converter from the very first
      //    buffer delivered after start.
      applyTapInstallResult(result, processingFormat: processingFormat)

      // 10. Restart engine if we stopped it
      if stopEngine {
        try unsafe engine.start()
      }

      return result
    }

    /// Applies tap install results to engine state.
    ///
    /// Thread Domain: engineControl (called from `reinstallTap` on the engine
    /// control queue, or from `warm()` on MainActor after the queue dispatch).
    package func applyTapInstallResult(_ result: TapInstallResult, processingFormat: AVAudioFormat)
    {
      let wrapped = state { state -> Transferring<TapSnapshot> in
        state.tapConverter = result.artifacts.converter
        state.tapConverterInputFormat = result.artifacts.inputFormat
        state.tapConverterOutputFormat = processingFormat
        state.tapConvertedBuffer = result.artifacts.convertedBuffer
        state.installedTapBus = result.tapConfiguration.bus
        return Transferring(
          TapSnapshot(
            audioBuffers: state.audioBuffers,
            receiverBuffers: state.receiverBuffers,
            receiverTiming: state.receiverTiming,
            converter: state.tapConverter,
            converterInputFormat: state.tapConverterInputFormat,
            converterOutputFormat: state.tapConverterOutputFormat,
            convertedBuffer: state.tapConvertedBuffer,
          ),
        )
      }
      recordingInfrastructure.tapSnapshotLock.withLock { $0 = wrapped.value }
    }
  }
#endif
