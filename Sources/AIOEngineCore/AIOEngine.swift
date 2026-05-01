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
  /// - ``onRecordingInterruption``
  /// - ``onRecordingStarted``
  /// - ``onRecordingCompleted``
  /// - ``onRecordingFailed``
  /// - ``errors``
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

    /// Errors that can occur during audio engine operations.
    public enum AIOError: AudioError, LocalizedError {
      public enum AudioSessionOperation: String, Sendable, Equatable, CustomStringConvertible {
        case setCategory
        case setPreferredSampleRate
        case setPreferredIOBufferDuration
        case setPreferredInputNumberOfChannels
        case setAllowHapticsAndSystemSoundsDuringRecording
        case setPrefersNoInterruptionsFromSystemAlerts
        case setPrefersInterruptionOnRouteDisconnect
        case setActive
        case setPreferredInput
        case overrideOutputAudioPort

        public var description: String {
          rawValue
        }
      }

      public enum AudioFileOperation: String, Sendable, Equatable, CustomStringConvertible {
        case openForReading
        case openForWriting
        case write

        public var description: String {
          rawValue
        }
      }

      /// The operation could not be completed because the engine is not currently recording.
      case notRecording
      /// The operation could not be completed because the engine is not currently playing audio.
      case notPlaying
      /// The operation could not be completed because the engine is already recording.
      case alreadyRecording
      /// The operation could not be completed because playback is not allowed while recording.
      case cannotPlayWhileRecording
      /// A generic error occurred in the audio engine.
      case engineError
      /// The audio format conversion failed.
      case formatConversionFailed
      /// The hardware does not support the requested configuration.
      case hardwareNotSupported
      /// The audio session is not ready.
      case audioSessionNotReady(details: String)
      /// The recording configuration is invalid.
      case invalidRecordingConfiguration(details: String)
      /// The requested recording channel count exceeds the selected format/runtime capacity.
      case unsupportedRecordingChannelCount(requested: Int, maximum: Int)
      /// The selected output encoder does not support the requested sample rate.
      case unsupportedEncodedSampleRate(
        fileFormat: FileFormat,
        sampleRate: Double,
        supportedSampleRates: [Double],
      )
      /// The scrub time is invalid.
      case invalidScrubTime(details: Double)
      /// The scrub track is invalid.
      case invalidScrubTrack
      /// The specified time range is invalid for segment playback.
      case invalidTimeRange
      /// The underlying `AVAudioEngine` failed to start.
      case engineStartFailed(error: ErrorContext)
      /// A system audio session operation failed.
      case audioSessionFailed(operation: AudioSessionOperation, error: ErrorContext)
      /// An audio file operation failed.
      case audioFileFailed(operation: AudioFileOperation, url: URL?, error: ErrorContext)

      public var errorDescription: String? {
        switch self {
        case .notRecording: return "Not currently recording"
        case .notPlaying: return "Not currently playing"
        case .alreadyRecording: return "Already recording"
        case .cannotPlayWhileRecording: return "Cannot play audio while recording"
        case .engineError: return "Audio engine error"
        case .formatConversionFailed: return "Failed to convert audio format"
        case .hardwareNotSupported: return "Hardware configuration not supported"
        case .audioSessionNotReady(let details):
          return "Audio session not ready: \(details)"
        case .invalidRecordingConfiguration(let details):
          return "The recording configuration was not valid. \(details)"
        case .unsupportedRecordingChannelCount(let requested, let maximum):
          return
            "Recording \(requested)-channel audio is not supported by the selected format/runtime. The current maximum is \(maximum) channels."
        case .unsupportedEncodedSampleRate(let fileFormat, let sampleRate, let supportedRates):
          let requested = Int((sampleRate / 1000).rounded())
          let supportedDescription =
            supportedRates
            .map { Int(($0 / 1000).rounded()) }
            .map { "\($0)kHz" }
            .joined(separator: ", ")
          return
            "The selected \(fileFormat.description) format does not support \(requested)kHz. Supported rates: \(supportedDescription)"
        case .invalidScrubTime(let details):
          return "Progress can only be scrubbed between 0..<1. (value: \(details))"
        case .invalidScrubTrack:
          return "A track must be playing to be scrubbed to a time"
        case .invalidTimeRange:
          return "The specified time range is invalid"
        case .engineStartFailed(let error):
          return "Audio engine failed to start: \(error)"
        case .audioSessionFailed(let operation, let error):
          return "Audio session operation '\(operation)' failed: \(error)"
        case .audioFileFailed(let operation, let url, let error):
          return
            "Audio file operation '\(operation)' failed for \(url?.lastPathComponent ?? "missing URL"): \(error)"
        }
      }

      public var description: String {
        errorDescription ?? String(describing: self)
      }

      /// Returns `true` if this error might be transient and worth retrying.
      public var isTransient: Bool {
        switch self {
        case .audioSessionNotReady:
          true
        default:
          false
        }
      }
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

    // MARK: - Callbacks

    /// A callback that is invoked when a recording interruption occurs.
    @MainActor public var onRecordingInterruption:
      (@Sendable @MainActor (RecordingInterruption) async -> Void)?

    /// A callback that is invoked when a recording starts.
    ///
    /// - Parameter url: The URL of the recording file.
    /// - Parameter format: The format of the recording file.
    @MainActor public var onRecordingStarted: (@Sendable @MainActor (URL, String) -> Void)?
    /// A callback that is invoked when a recording completes successfully.
    @MainActor public var onRecordingCompleted: (@Sendable @MainActor () -> Void)?
    /// A callback that is invoked when a recording fails.
    @MainActor public var onRecordingFailed: (@Sendable @MainActor () -> Void)?
    /// Called when a recording segment is completed (file rotated).
    /// The handler receives the URL of the completed segment and its format.
    @MainActor public var onSegmentCompleted: (@Sendable @MainActor (URL, String) -> Void)?

    /// Called when the engine fails to reconcile the desired recording state
    /// with the actual state after the configured timeout.
    ///
    /// - Parameter desiredState: The state that could not be achieved.
    @MainActor public var onReconciliationFailed: (@Sendable @MainActor (Bool) -> Void)?
    /// Called when the playback item or playback state changes (play/pause/stop), excluding time ticks.
    @MainActor public var onPlaybackStateChanged: (@Sendable @MainActor (Playback?) -> Void)?
    /// Called on every playback update including time ticks.
    ///
    /// Use this to mirror playback state into a local `@Observable` stored property
    /// so that SwiftUI observation reliably fires for downstream views.
    @MainActor public var onPlaybackUpdated: (@Sendable @MainActor (Playback?) -> Void)?

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

    @MainActor package var reconciliationTask: Task<Void, Never>? {
      get { recordingRuntimeContext.reconciliationTask }
      set {
        recordingRuntimeContext.reconciliationTask?.cancel()
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

    @MainActor package var lastRecordingStartFailure: AIOError? {
      get { recordingRuntimeContext.lastRecordingStartFailure as? AIOError }
      set { recordingRuntimeContext.lastRecordingStartFailure = newValue }
    }

    #if DEBUG
      /// Test hook: when set, `reinstallTap()` calls this instead of touching AVAudioEngine.
      @MainActor package var testReinstallTapOverride:
        (
          @MainActor (RecordingConfiguration, AVAudioFormat) throws(AIOError) -> TapInstallResult
        )?
    #endif

    @MainActor package var playbackTask: Task<Void, Never>? {
      get { playbackRuntimeContext.playbackTask }
      set {
        playbackRuntimeContext.playbackTask?.cancel()
        playbackRuntimeContext.playbackTask = newValue
      }
    }

    @MainActor package var scrubTask: Task<Void, Never>? {
      get { playbackRuntimeContext.scrubTask }
      set {
        playbackRuntimeContext.scrubTask?.cancel()
        playbackRuntimeContext.scrubTask = newValue
      }
    }

    public let bufferReceivers: Synchronized<[any BufferReceiver<Float>]> = .init([])

    package let clock = ContinuousClock()

    package let errorSubject: Subject<any Error> = .init()

    /// An asynchronous stream of errors that occur in the audio engine.
    public var errors: AsyncBroadcaster<any Error> {
      errorSubject.broadcaster
    }

    /// Returns the most recent failure encountered while starting recording and clears it.
    @MainActor
    public func consumeLastRecordingStartFailure() -> AIOError? {
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
          try? await Task.sleep(for: timeout)
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
        onPlaybackStateChanged?(playback)
      }
      onPlaybackUpdated?(playback)
    }

    package func getPlayback() -> Playback? {
      guard let playbackInstance = playbackState[locked: \.playbackInstance] else { return nil }
      return getPlayback(for: playbackInstance)
    }

    package func getPlayback(for instance: PlaybackInstance) -> Playback {
      guard let nodeTime = unsafe player.lastRenderTime,
        let playerTime = unsafe player.playerTime(forNodeTime: nodeTime)
      else {
        return unsafe Playback(
          id: instance.id,
          file: instance.file.url,
          isPlaying: player.isPlaying,
          time: instance.playbackTime(forAbsoluteFrame: instance.startFrame),
          duration: instance.duration,
        )
      }

      let sampleRate = playerTime.sampleRate
      let timeInPlayer = Double(playerTime.sampleTime) / sampleRate
      let renderedFrames = AVAudioFramePosition(
        timeInPlayer * instance.file.processingFormat.sampleRate)
      let currentAbsoluteFrame = instance.startFrame + renderedFrames

      return unsafe Playback(
        id: instance.id,
        file: instance.file.url,
        isPlaying: player.isPlaying,
        time: instance.playbackTime(forAbsoluteFrame: currentAbsoluteFrame),
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
        let error: AIOError =
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
        errorSubject.send(error)
      }
      return (poll, handler)
    }
  }
#endif
