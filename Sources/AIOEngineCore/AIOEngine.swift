// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOContracts
  import AIOSupport
  package import AIORecordingSupport
  import AsyncAlgorithms
  package import Atomics
  package import AVFoundation
  import Dispatch
  import Foundation
  import Observation
  import os
  import Tools

  private let log = SystemLog.make()
  #if DEBUG
    package let rtLoggingEnabled: Bool = ProcessInfo.processInfo.environment["AIO_RT_LOGS"] == "1"
  #else
    package let rtLoggingEnabled = false
  #endif

  /// The core audio recording and playback engine.
  ///
  /// `AIOEngine` provides a high-level interface for capturing and playing back audio, built on top of `AVFoundation`.
  /// It manages the audio engine, session, and I/O, providing real-time audio data through a `BufferReceiver` protocol.
  ///
  /// ## Topics
  ///
  /// ### Creating an Engine
  ///
  /// - ``init()``
  ///
  /// ### Recording Audio
  ///
  /// - ``startRecording(configuration:)``
  /// - ``stopRecording()``
  /// - ``warm(configuration:)``
  /// - ``isRecording``
  ///
  /// ### Playing Audio
  ///
  /// - ``play(url:)``
  /// - ``stopPlayback()``
  /// - ``scrubPlay(to:)``
  /// - ``isPlayback``
  /// - ``isPlaying``
  /// - ``playback``
  ///
  /// ### Handling Events
  ///
  /// - ``events``
  /// - ``AudioIOEvent``
  ///
  /// ### Attaching Receivers
  ///
  /// - ``attachBufferReceiver(_:)``
  /// - ``detachBufferReceivers()``
  ///
  /// ### Managing Audio system events
  ///
  /// - ``handleRouteChange(event:)``
  /// - ``handleInterruption(type:options:)``
  /// - ``handleMediaServicesLost()``
  /// - ``handleMediaServicesReset()``
  ///
  @Observable
  public final class AIOEngine: Sendable {
    public enum AudioSessionPolicy: Sendable {
      /// `AIOEngine` configures and activates/deactivates `AVAudioSession` directly.
      case engineManaged
      /// A higher-level owner (e.g. `AudioEnvironmentManager`) handles activation state.
      case delegated(setActive: @MainActor @Sendable (Bool) throws -> Void)
    }

    /// An event representing a change in audio quality.
    public struct AudioQualityChange: Sendable {
      public init(
        reason: String,
        previousChannels: UInt32,
        currentChannels: UInt32,
        previousSampleRate: Double,
        currentSampleRate: Double,
      ) {
        self.reason = reason
        self.previousChannels = previousChannels
        self.currentChannels = currentChannels
        self.previousSampleRate = previousSampleRate
        self.currentSampleRate = currentSampleRate
      }

      /// The reason for the quality change.
      public let reason: String
      /// The previous number of channels.
      public let previousChannels: UInt32
      /// The current number of channels.
      public let currentChannels: UInt32
      /// The previous sample rate.
      public let previousSampleRate: Double
      /// The current sample rate.
      public let currentSampleRate: Double

      public var description: String {
        "Format changed: \(previousChannels)ch@\(Int(previousSampleRate))Hz → \(currentChannels)ch@\(Int(currentSampleRate))Hz"
      }
    }

    /// An event representing a recording interruption.
    public enum RecordingInterruption: Sendable {
      /// The audio route changed, but recording is continuing.
      case routeChangeContinuing(event: AudioRouteChangeEvent, qualityChange: AudioQualityChange?)
      /// The recording was stopped gracefully.
      case stoppedGracefully(reason: String)
      /// The recording was stopped by an interruption (e.g., a phone call).
      case stoppedByInterruption(reason: String)

      public var description: String {
        switch self {
        case .routeChangeContinuing(let event, let qualityChange):
          if let change = qualityChange {
            "\(event.userMessage), continuing with: \(change.description)"
          } else {
            "\(event.userMessage), continuing with same quality"
          }
        case .stoppedGracefully(let reason):
          "Recording stopped gracefully: \(reason)"
        case .stoppedByInterruption(let reason):
          "Recording interrupted: \(reason)"
        }
      }
    }

    /// A struct representing the current playback state.
    public struct Playback: Sendable, Hashable, Identifiable, Codable {
      public init(
        id: UUID, file: URL, isPlaying: Bool, time: TimeInterval? = nil, duration: TimeInterval,
      ) {
        self.id = id
        self.file = file
        self.isPlaying = isPlaying
        self.time = time
        self.duration = duration
      }

      /// The unique identifier of the playback instance.
      public let id: UUID
      /// The URL of the file being played.
      public let file: URL
      /// A Boolean value that indicates whether the audio is currently playing.
      public let isPlaying: Bool
      /// The current playback time in seconds.
      ///
      /// Segment playback reports time relative to the segment start; whole-file playback
      /// reports time relative to the file start.
      public let time: TimeInterval?
      /// The duration of the active playback item in seconds.
      ///
      /// Segment playback reports segment duration; whole-file playback reports file duration.
      public let duration: TimeInterval
    }

    // MARK: - Thread Domains

    //
    // AIOEngine uses five distinct thread domains. Each property and method
    // belongs to exactly one domain. Cross-domain communication uses only
    // lock-free primitives (ManagedAtomic, SPSCRingBuffer) or non-blocking
    // snapshot reads.
    //
    // ┌─────────────────────────────────────────────────────────────────┐
    // │                   MainActor (UI / State)                       │
    // │  isRecording, playback, reconciliation, callbacks,             │
    // │  AVAudioSession configuration, lifecycle coordination          │
    // └──────────────────┬──────────────────────┬──────────────────────┘
    //                    │                      │
    //           sync dispatch              async dispatch
    //                    │                      │
    // ┌──────────────────▼──────────────────┐   │
    // │     engineControlQueue (serial)     │   │
    // │  attach, connect, start, stop,      │   │
    // │  prepare, reset, installTap         │   │
    // └──────────────────┬──────────────────┘   │
    //                    │                      │
    //             [AVAudioEngine                │
    //              manages internally]          │
    //                    │                      │
    // ┌──────────────────▼──────────────────┐   │
    // │       Tap Thread (semi-RT)          │   │
    // │  processAudio() — convert, enqueue  │   │
    // │  to SPSC ring buffers               │   │
    // │  Lock-free reads via TapSnapshot    │   │
    // └────┬──────────────────────┬─────────┘   │
    //      │ SPSC                 │ SPSC        │
    //      ▼                      ▼             │
    // ┌────────────┐    ┌──────────────────┐    │
    // │ writerQueue│    │  receiverQueue   │◄───┘
    // │ (file I/O) │    │ (visualization)  │
    // └────────────┘    └──────────────────┘
    //
    // Synchronization mechanisms:
    // - MainActor ↔ engineControlQueue: sync/async dispatch
    // - engineControlQueue ↔ tapThread: TapSnapshot (lock-free), ManagedAtomic
    // - tapThread ↔ writerQueue: SPSCRingBuffer, ManagedAtomic
    // - tapThread ↔ receiverQueue: SPSCRingBuffer, ManagedAtomic

    // MARK: - Stored Properties

    // SAFETY: AVAudioEngine and AVAudioPlayerNode are mutable Apple framework
    // types that cannot adopt Sendable. All graph mutations go through
    // `engineControlQueue` (a serial DispatchQueue) via the
    // runOnEngineControlQueue / withEngineControlQueue helpers below. The
    // real-time tap callback thread reads a reference captured at install
    // time and communicates with the control thread via lock-free
    // SPSCRingBuffers + ManagedAtomic. See the architecture block above for
    // the full thread topology. Swift's type system cannot model dispatch
    // queue serialization, so the `nonisolated(unsafe)` annotation tells it
    // "trust me, this is covered by the queue invariant."
    package nonisolated(unsafe) let engine = AVAudioEngine()
    // SAFETY: Same queue invariant as `engine` above — player is an
    // AVAudioPlayerNode attached to the engine graph and mutated only from
    // engineControlQueue.
    package nonisolated(unsafe) let player = AVAudioPlayerNode()
    package let engineControlQueue = DispatchQueue(label: "AIOEngine.engine-control", qos: .default)
    package let recordingInfrastructure = RecordingInfrastructure()
    @MainActor package var recordingRuntimeContext = RecordingRuntimeState()
    @MainActor package var playbackRuntimeContext = PlaybackRuntimeContext()

    package let playbackState: Synchronized<PlaybackRuntimeState> = .init(.init())

    // MARK: - Tap Snapshot Lock

    /// Cached snapshot of tap-relevant state for low-contention reads in `processAudio()`.
    ///
    /// Thread Domain: tapCallback (read via `withLockIfAvailable`),
    /// MainActor + engineControl + writerQueue (write via `withLock`).
    ///
    /// This is a separate, lightweight lock dedicated to the tap snapshot. Unlike the
    /// main `state` lock (which protects all of `RecordingState` and can be held during
    /// complex operations), this lock is only held for trivial struct copies —
    /// nanosecond-scale. The tap thread uses `withLockIfAvailable` so it never blocks
    /// if a writer is to be updating concurrently.
    ///
    /// The brief staleness window (one or two tap callbacks using the previous snapshot
    /// if the lock is contended during a write) is safe because the old converter
    /// remains valid until the engine is stopped and restarted.
    package var writerQueue: DispatchQueue {
      recordingInfrastructure.writerQueue
    }

    package var receiverQueue: DispatchQueue {
      recordingInfrastructure.receiverQueue
    }

    package var recordingSampleTimeAtomic: ManagedAtomic<Int64> {
      recordingInfrastructure.recordingSampleTimeAtomic
    }

    package var recordingFirstHostTimeAtomic: ManagedAtomic<UInt64> {
      recordingInfrastructure.recordingFirstHostTimeAtomic
    }

    package var recordingFirstSourceSampleTimeAtomic: ManagedAtomic<Int64> {
      recordingInfrastructure.recordingFirstSourceSampleTimeAtomic
    }

    package var writerDrainTimeout: Duration {
      recordingInfrastructure.writerDrainTimeout
    }

    package var stopDrainTimeout: Duration {
      recordingInfrastructure.stopDrainTimeout
    }

    package var receiverPollingInterval: Duration {
      recordingInfrastructure.receiverPollingInterval
    }

    package var maxBufferSeconds: Double {
      recordingInfrastructure.maxBufferSeconds
    }

    package var tapErrorCode: ManagedAtomic<Int> {
      recordingInfrastructure.tapErrorCode
    }

    package var tapResizeRequestedFrames: ManagedAtomic<Int> {
      recordingInfrastructure.tapResizeRequestedFrames
    }

    package var metrics: EngineMetrics {
      recordingInfrastructure.metrics
    }

    package var state: Synchronized<RecordingState> {
      recordingInfrastructure.state
    }

    /// A Boolean value that indicates whether the engine is currently recording.
    @MainActor public package(set) var isRecording: Bool = false

    /// The user's desired recording state.
    @MainActor public package(set) var wantsRecording: Bool = false

    /// Configuration for state reconciliation attempts.
    @MainActor public var reconciliationConfiguration: ReconciliationConfiguration {
      get { recordingRuntimeContext.reconciliationConfiguration }
      set { recordingRuntimeContext.reconciliationConfiguration = newValue }
    }

    /// Preferred audio session category/mode/options for this engine.
    @MainActor public var recordingSessionConfiguration: AudioSessionConfiguration {
      get { recordingRuntimeContext.recordingSessionConfiguration }
      set { recordingRuntimeContext.recordingSessionConfiguration = newValue }
    }
    /// Policy controlling whether the engine mutates `AVAudioSession` directly
    /// or delegates activation to a higher-level session authority.
    @MainActor public var audioSessionDelegate: (any AudioSessionDelegate)?
    @MainActor public var sessionConfiguration: AudioSessionConfiguration {
      get { recordingSessionConfiguration }
      set { recordingSessionConfiguration = newValue }
    }

    /// Backend used for audio file writing.
    @MainActor package var writerBackend: WriterBackend {
      get { recordingRuntimeContext.writerBackend }
      set { recordingRuntimeContext.writerBackend = newValue }
    }
    /// Whether the engine should deactivate the audio session when it becomes idle.
    ///
    /// Leave this `false` when a higher-level manager owns session lifecycle.
    @MainActor public var deactivateAudioSessionOnStop: Bool {
      get { recordingRuntimeContext.deactivateAudioSessionOnStop }
      set { recordingRuntimeContext.deactivateAudioSessionOnStop = newValue }
    }

    @MainActor package var lastRecordingConfiguration: RecordingConfiguration? {
      get { recordingRuntimeContext.lastRecordingConfiguration }
      set { recordingRuntimeContext.lastRecordingConfiguration = newValue }
    }

    @MainActor package var pendingRecordingRestart: RecordingConfiguration? {
      get { recordingRuntimeContext.pendingRecordingRestart }
      set { recordingRuntimeContext.pendingRecordingRestart = newValue }
    }

    @MainActor package var pendingPlaybackResume: PlaybackResume? {
      get { playbackRuntimeContext.pendingPlaybackResume }
      set { playbackRuntimeContext.pendingPlaybackResume = newValue }
    }

    @MainActor package var receiverSession: ReceiverSession? {
      get { recordingRuntimeContext.receiverSession }
      set { recordingRuntimeContext.receiverSession = newValue }
    }

    @MainActor package var reconciliationTask: MainActorOwnedWork? {
      get { recordingRuntimeContext.reconciliationTask }
      set {
        recordingRuntimeContext.reconciliationTask?.cancelNow()
        recordingRuntimeContext.reconciliationTask = newValue
      }
    }

    /// The current playback state, or `nil` if no audio is playing.
    @MainActor public internal(set) var playback: Playback?
    /// The default interval used to refresh `playback.time` while playback is active.
    ///
    /// This is intentionally coarse by default to avoid excessive observation churn in UI.
    ///
    /// Per-playback overrides can be provided via `play(url:playbackPollingInterval:)`
    /// and `playSegment(..., playbackPollingInterval:)`.
    ///
    /// Values `<= .zero` are treated as `.seconds(0.5)`.
    @MainActor public var defaultPlaybackPollingInterval: Duration {
      get { playbackRuntimeContext.defaultPlaybackPollingInterval }
      set { playbackRuntimeContext.defaultPlaybackPollingInterval = newValue }
    }

    @MainActor var lastPlaybackStateSignature: PlaybackStateSignature? {
      get { playbackRuntimeContext.lastPlaybackStateSignature }
      set { playbackRuntimeContext.lastPlaybackStateSignature = newValue }
    }

    /// A Boolean value that indicates whether the engine is currently playing back audio.
    @MainActor public var isPlayback: Bool {
      playback != nil
    }

    /// A Boolean value that indicates whether the player is currently playing.
    @MainActor public var isPlaying: Bool {
      playback?.isPlaying == true
    }

    @MainActor package var writerSession: WriterSession? {
      get { recordingRuntimeContext.writerSession }
      set { recordingRuntimeContext.writerSession = newValue }
    }

    @MainActor package var drainingWriterSessions: [WriterSession] {
      get { recordingRuntimeContext.drainingWriterSessions }
      set { recordingRuntimeContext.drainingWriterSessions = newValue }
    }

    @MainActor package var lastWriteFailure: WriteFailure? {
      get { recordingRuntimeContext.lastWriteFailure }
      set { recordingRuntimeContext.lastWriteFailure = newValue }
    }

    @MainActor package var lastRecordingStartFailure: RecordingError? {
      get { recordingRuntimeContext.lastRecordingStartFailure as? RecordingError }
      set { recordingRuntimeContext.lastRecordingStartFailure = newValue }
    }

    #if DEBUG
      /// Test hook: when set, `reinstallTap()` calls this instead of touching AVAudioEngine.
      @MainActor package var testReinstallTapOverride:
        (
          @MainActor (RecordingConfiguration, AVAudioFormat) throws(RecordingError) ->
            TapInstallResult
        )?

      /// Test hook: when set, the recording-engine teardown paths (`gracefulStop()`
      /// and `hardStop()`) invoke this in place of the real `AVAudioEngine` graph
      /// teardown (tap removal + `engine.stop()`/`reset()`), which crashes the iOS
      /// Simulator audio HAL (`AURemoteIO -10851`). Everything else — writer drain,
      /// cleanup, and the `isRecording`/`wantsRecording` transitions — still runs, so
      /// interruption, resume, and stop logic stays under test without a real audio
      /// device.
      @MainActor package var testEngineTeardownOverride:
        (@MainActor () -> Void)?
    #endif

    @MainActor package var playbackTask: MainActorOwnedWork? {
      get { playbackRuntimeContext.playbackTask }
      set {
        playbackRuntimeContext.playbackTask?.cancelNow()
        playbackRuntimeContext.playbackTask = newValue
      }
    }

    @MainActor package var scrubTask: MainActorOwnedWork? {
      get { playbackRuntimeContext.scrubTask }
      set {
        playbackRuntimeContext.scrubTask?.cancelNow()
        playbackRuntimeContext.scrubTask = newValue
      }
    }

    package let bufferReceivers: Synchronized<[any BufferReceiver<Float>]> = .init([])
    package let playbackCallbackTasks = AsyncTaskRunner()
    package let recordingCallbackTasks = AsyncTaskRunner()

    package let clock = ContinuousClock()

    package let eventSubject: Subject<AudioIOEvent> = .init()

    /// The unified event stream for the audio engine.
    ///
    /// Subscribe via `for await event in engine.events { ... }` and
    /// pattern-match on the case. The stream is the canonical surface for
    /// engine notifications — engine-level errors, recording lifecycle
    /// (started / completed / failed / interrupted /
    /// reconciliation-failed), and playback lifecycle (state changes and
    /// per-tick updates). See ``AudioIOEvent`` for the full case list.
    public var events: AsyncBroadcaster<AudioIOEvent> {
      eventSubject.broadcaster
    }

    /// Returns the most recent failure encountered while starting recording and clears it.
    @MainActor
    public func consumeLastRecordingStartFailure() -> RecordingError? {
      defer { lastRecordingStartFailure = nil }
      return lastRecordingStartFailure
    }

    // MARK: - Initialization

    /// Creates a new instance of the audio engine.
    public init() {
      runOnEngineControlQueue { [engine = unsafe engine, player = unsafe player] in
        engine.attach(player)
      }
    }

    /// Creates a new instance of the audio engine with custom reconciliation configuration.
    ///
    /// - Parameter reconciliationConfiguration: Configuration for state reconciliation.
    @MainActor public init(reconciliationConfiguration: ReconciliationConfiguration) {
      self.reconciliationConfiguration = reconciliationConfiguration
      runOnEngineControlQueue { [engine = unsafe engine, player = unsafe player] in
        engine.attach(player)
      }
    }

    // MARK: - Engine Control Queue Helpers

    /// Thread Domain: engineControl
    /// All AVAudioEngine graph mutations must go through these helpers.
    ///
    package nonisolated func runOnEngineControlQueue<T>(_ work: () -> T) -> T {
      engineControlQueue.sync(execute: work)
    }

    package nonisolated func runOnEngineControlQueueResult<T>(
      _ work: () throws -> T,
    ) -> Result<T, any Error> {
      engineControlQueue.sync {
        Result { try work() }
      }
    }

    package nonisolated func withEngineControlQueue<T>(
      _ work: @escaping @Sendable () -> T,
    ) async -> T {
      await withCheckedContinuation { continuation in
        engineControlQueue.async {
          let result = work()
          continuation.resume(returning: result)
        }
      }
    }

    package nonisolated func withEngineControlQueueResult<T>(
      _ work: @escaping @Sendable () throws -> T,
    ) async -> Result<T, any Error> {
      await withCheckedContinuation { continuation in
        engineControlQueue.async {
          let result = Result { try work() }
          continuation.resume(returning: result)
        }
      }
    }

    // MARK: - Atomic State Helpers

    package nonisolated func recordTapError(_ code: TapErrorCode) {
      tapErrorCode.store(code.rawValue, ordering: .relaxed)
    }

    package nonisolated func requestTapResize(frames: Int) {
      guard frames > 0 else { return }
      var current = tapResizeRequestedFrames.load(ordering: .relaxed)
      while frames > current {
        let result = tapResizeRequestedFrames.compareExchange(
          expected: current,
          desired: frames,
          ordering: .acquiringAndReleasing,
        )
        if result.exchanged { break }
        current = result.original
      }
    }

    package nonisolated func consumeTapError() -> TapErrorCode? {
      let raw = tapErrorCode.load(ordering: .relaxed)
      guard raw != 0, let code = TapErrorCode(rawValue: raw) else { return nil }
      tapErrorCode.store(0, ordering: .relaxed)
      return code
    }

    package nonisolated func consumeTapResizeRequest() -> Int {
      tapResizeRequestedFrames.exchange(0, ordering: .acquiringAndReleasing)
    }

    package nonisolated func isDrainSatisfiedByTarget(_ session: WriterSession) -> Bool {
      let target = session.control.targetSampleTime.load(ordering: .relaxed)
      let written = session.control.writtenSampleTime.load(ordering: .relaxed)
      let stopRequested = session.control.stopRequested.load(ordering: .relaxed)
      return stopRequested && written >= target
    }

    package nonisolated func awaitWriterDrainOutcome(_ session: WriterSession) async
      -> WriterDrainOutcome
    {
      log.info(
        "🧹 awaitWriterDrain start for \(session.fileURL.lastPathComponent, privacy: .public)",
      )
      if Task.isCancelled {
        log.warning(
          "🧹 awaitWriterDrain cancelled for \(session.fileURL.lastPathComponent, privacy: .public)",
        )
        return .timedOut
      }
      if isDrainSatisfiedByTarget(session) {
        return .targetSatisfied
      }

      let timeout = writerDrainTimeout
      let timeoutPolicy = TimeoutPolicy(timeout)
      let outcome = await withTaskGroup(of: WriterDrainOutcome.self) { group in
        group.addTask {
          await session.control.drainSignal.wait()
          return .signaled
        }
        group.addTask {
          await session.control.targetSatisfiedSignal.wait()
          return .targetSatisfied
        }
        group.addTask {
          try? await timeoutPolicy.waitForTimeout()
          return .timedOut
        }

        let first = await group.next() ?? .timedOut
        group.cancelAll()
        return first
      }

      if outcome == .timedOut, isDrainSatisfiedByTarget(session) {
        return .targetSatisfied
      }
      if outcome == .signaled {
        log.info(
          "🧹 awaitWriterDrain completed for \(session.fileURL.lastPathComponent, privacy: .public)",
        )
      }
      return outcome
    }

    // MARK: - Playback State Helpers

    package struct PlaybackStateSignature: Equatable {
      package let id: UUID?
      package let file: URL?
      package let isPlaying: Bool

      package init(playback: Playback?) {
        id = playback?.id
        file = playback?.file
        isPlaying = playback?.isPlaying ?? false
      }
    }

    @MainActor
    package func setPlayback(_ new: Playback?) {
      let previousSignature = PlaybackStateSignature(playback: playback)

      let updated: Playback? =
        if let playbackInstance = playbackState[locked: \.playbackInstance],
          new?.id == playbackInstance.id
        {
          new
        } else if new == nil {
          nil
        } else {
          // Ignore stale updates for a previous playback instance.
          playback
        }

      playback = updated

      let newSignature = PlaybackStateSignature(playback: playback)
      if previousSignature != newSignature, lastPlaybackStateSignature != newSignature {
        lastPlaybackStateSignature = newSignature
        eventSubject.send(AudioIOEvent.playbackStateChanged(playback))
      }
      eventSubject.send(AudioIOEvent.playbackUpdated(playback))
    }

    package func getPlayback() -> Playback? {
      guard let playbackInstance = playbackState[locked: \.playbackInstance] else { return nil }
      return getPlayback(for: playbackInstance)
    }

    package func getPlayback(for instance: PlaybackInstance) -> Playback {
      guard let nodeTime = unsafe player.lastRenderTime,
        let playerTime = unsafe player.playerTime(forNodeTime: nodeTime)
      else {
        // The node can't report a live position (paused, or not yet
        // rendering). The node still holds the real position and resumes from
        // it, so report the last observed position rather than snapping back to
        // the segment start. Falls back to the start frame only when no live
        // position has been observed for this instance (fresh play / seek).
        let memo = playbackState[locked: \.lastObservedPlaybackTime]
        let fallbackTime =
          (memo?.instanceID == instance.id ? memo?.time : nil)
          ?? instance.playbackTime(forAbsoluteFrame: instance.startFrame)
        return unsafe Playback(
          id: instance.id,
          file: instance.file.url,
          isPlaying: player.isPlaying,
          time: fallbackTime,
          duration: instance.duration,
        )
      }

      let sampleRate = playerTime.sampleRate
      let timeInPlayer = Double(playerTime.sampleTime) / sampleRate
      let renderedFrames = AVAudioFramePosition(
        timeInPlayer * instance.file.processingFormat.sampleRate)
      let currentAbsoluteFrame = instance.startFrame + renderedFrames
      let liveTime = instance.playbackTime(forAbsoluteFrame: currentAbsoluteFrame)
      playbackState[locked: \.lastObservedPlaybackTime] = ObservedPlaybackTime(
        instanceID: instance.id,
        time: liveTime,
      )

      return unsafe Playback(
        id: instance.id,
        file: instance.file.url,
        isPlaying: player.isPlaying,
        time: liveTime,
        duration: instance.duration,
      )
    }

    // MARK: - Tap Error Handler Factory

    package func resizeTapConvertedBufferIfNeeded() {
      let requested = consumeTapResizeRequest()
      guard requested > 0 else { return }
      let (existingCapacity, processingFormat) = state.withLock { state in
        (state.tapConvertedBuffer?.frameCapacity, state.tapConverterOutputFormat)
      }
      guard let processingFormat else { return }
      let current = Int(existingCapacity ?? 0)
      guard requested > current else { return }
      let targetCapacity = AVAudioFrameCount(requested)
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: targetCapacity,
        )
      else {
        log.error(
          "Failed to resize tap buffer to \(requested, privacy: .public) frames",
        )
        return
      }
      let wrapped = state.withLock { state -> Transferring<TapSnapshot> in
        state.tapConvertedBuffer = buffer
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
      log.warning(
        "Resized tap buffer to \(requested, privacy: .public) frames",
      )
    }

    /// Creates a matched pair of tap-error poll/handler closures for writer and receiver loops.
    package func makeTapErrorHandlers() -> (
      poll: @Sendable () -> TapErrorCode?,
      handler: @Sendable (TapErrorCode) -> Void,
    ) {
      let poll: @Sendable () -> TapErrorCode? = { [weak self] in
        self?.consumeTapError()
      }
      let handler: @Sendable (TapErrorCode) -> Void = { [weak self] code in
        guard let self else { return }
        let error: RecordingError =
          switch code {
          case .converterMissing, .bufferTooSmall, .conversionFailed:
            .formatConversionFailed
          }
        resizeTapConvertedBufferIfNeeded()
        let description =
          switch code {
          case .converterMissing: "converterMissing"
          case .bufferTooSmall: "bufferTooSmall"
          case .conversionFailed: "conversionFailed"
          }
        log.error("Tap error: \(description, privacy: .public)")
        eventSubject.send(AudioIOEvent.error(error))
      }
      return (poll, handler)
    }
  }
#endif
