#if !os(macOS) || targetEnvironment(macCatalyst)
@preconcurrency import AVFoundation
import AudioToolbox
import AsyncAlgorithms
import Atomics
import Dispatch
import Foundation
import SystemLog
import Tools

#if os(iOS)
private typealias OutputFileProtection = FileProtectionType
#else
private typealias OutputFileProtection = Never
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
/// ### Managing Audio Routes
///
/// - ``switchInput(to:)``
/// - ``switchOutput(to:)``
/// - ``handleRouteChange(event:)``
/// - ``handleInterruption(type:options:)``
///
private let log = SystemLog.make()

private struct EmptyAudioFileError: LocalizedError, Sendable {
  let url: URL

  var errorDescription: String? {
    "Audio file is empty: \(url.lastPathComponent)"
  }
}

private struct MissingAudioFileError: LocalizedError, Sendable {
  let url: URL

  var errorDescription: String? {
    "Audio file is missing: \(url.lastPathComponent)"
  }
}

private enum WriterBackend: Sendable {
  case avAudioFile
  case extAudioFile
}

private protocol RecordingFileWriter: Sendable {
  var fileURL: URL { get }
  func write(_ buffer: AVAudioPCMBuffer) throws
  func close()
}

private final class AVAudioFileWriter: @unchecked Sendable, RecordingFileWriter {
  let file: AVAudioFile
  let fileURL: URL

  init(file: AVAudioFile) {
    self.file = file
    self.fileURL = file.url
  }

  func write(_ buffer: AVAudioPCMBuffer) throws {
    try file.write(from: buffer)
  }

  func close() {
    file.close()
  }
}

private final class ExtAudioFileWriter: @unchecked Sendable, RecordingFileWriter {
  let fileURL: URL
  private var file: ExtAudioFileRef?

  init(
    url: URL,
    fileType: AudioFileTypeID,
    outputFormat: AVAudioFormat,
    clientFormat: AVAudioFormat
  ) throws {
    self.fileURL = url
    var asbd = outputFormat.streamDescription.pointee
    var newFile: ExtAudioFileRef?
    let status = ExtAudioFileCreateWithURL(
      url as CFURL,
      fileType,
      &asbd,
      nil,
      AudioFileFlags.eraseFile.rawValue,
      &newFile
    )
    guard status == noErr, let created = newFile else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
    }
    file = created
    var clientASBD = clientFormat.streamDescription.pointee
    let propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let setStatus = ExtAudioFileSetProperty(
      created,
      kExtAudioFileProperty_ClientDataFormat,
      propertySize,
      &clientASBD
    )
    guard setStatus == noErr else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(setStatus), userInfo: nil)
    }
  }

  func write(_ buffer: AVAudioPCMBuffer) throws {
    guard let file else { return }
    let frames = buffer.frameLength
    let status = ExtAudioFileWrite(file, frames, buffer.audioBufferList)
    guard status == noErr else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
    }
  }

  func close() {
    if let file {
      ExtAudioFileDispose(file)
      self.file = nil
    }
  }
}

private struct WriterDrainTimeoutError: LocalizedError, Sendable {
  let url: URL
  let timeout: Duration

  var errorDescription: String? {
    "Writer drain timed out after \(timeout.seconds) seconds for \(url.lastPathComponent)"
  }
}

private actor WriterDrainSignal {
  private var isSignaled = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func isSignaledValue() -> Bool {
    isSignaled
  }

  func wait() async {
    if isSignaled { return }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func signal() {
    guard !isSignaled else { return }
    isSignaled = true
    let pending = continuations
    continuations.removeAll()
    for continuation in pending {
      continuation.resume()
    }
  }
}

private final class WriterControl: @unchecked Sendable {
  let stopRequested = ManagedAtomic<Bool>(false)
  let cancelRequested = ManagedAtomic<Bool>(false)
  let drainSignal = WriterDrainSignal()
  let writtenSampleTime = ManagedAtomic<Int64>(0)
  let targetSampleTime = ManagedAtomic<Int64>(0)
}

private struct WriterSession: Sendable {
  let id: UUID
  let control: WriterControl
  let writer: RecordingFileWriter
  let fileURL: URL
}

@Observable
public final class AIOEngine: Sendable {
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

      public var description: String { rawValue }
    }

    public enum AudioFileOperation: String, Sendable, Equatable, CustomStringConvertible {
      case openForReading
      case openForWriting
      case write

      public var description: String { rawValue }
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
    case audioFileFailed(operation: AudioFileOperation, url: URL, error: ErrorContext)

    public var errorDescription: String? {
      switch self {
      case .notRecording: "Not currently recording"
      case .notPlaying: "Not currently playing"
      case .alreadyRecording: "Already recording"
      case .cannotPlayWhileRecording: "Cannot play audio while recording"
      case .engineError: "Audio engine error"
      case .formatConversionFailed: "Failed to convert audio format"
      case .hardwareNotSupported: "Hardware configuration not supported"
      case .audioSessionNotReady(let details):
        "Audio session not ready: \(details)"
      case .invalidRecordingConfiguration(let details):
        "The recording configuration was not valid. \(details)"
      case .invalidScrubTime(let details):
        "Progress can only be scrubbed between 0..<1. (value: \(details))"
      case .invalidScrubTrack:
        "A track must be playing to be scrubbed to a time"
      case .invalidTimeRange:
        "The specified time range is invalid"
      case .engineStartFailed(let error):
        "Audio engine failed to start: \(error)"
      case .audioSessionFailed(let operation, let error):
        "Audio session operation '\(operation)' failed: \(error)"
      case .audioFileFailed(let operation, let url, let error):
        "Audio file operation '\(operation)' failed for \(url.lastPathComponent): \(error)"
      }
    }

    public var description: String {
      errorDescription ?? String(describing: self)
    }

    /// Returns `true` if this error might be transient and worth retrying.
    public var isTransient: Bool {
      switch self {
      case .audioSessionNotReady:
        return true
      default:
        return false
      }
    }
  }

  /// An event representing a change in audio quality.
  public struct AudioQualityChange: Sendable {
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
          return "\(event.userMessage), continuing with: \(change.description)"
        } else {
          return "\(event.userMessage), continuing with same quality"
        }
      case .stoppedGracefully(let reason):
        return "Recording stopped gracefully: \(reason)"
      case .stoppedByInterruption(let reason):
        return "Recording interrupted: \(reason)"
      }
    }
  }

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

  private let engine = AVAudioEngine()
  private nonisolated let player = AVAudioPlayerNode()
  private let engineControlQueue = DispatchQueue(label: "AIOEngine.engine-control", qos: .default)
  private let writerQueue = DispatchQueue(label: "AIOEngine.writer", qos: .userInitiated)

  private let recordingSampleTimeAtomic = ManagedAtomic<Int64>(0)
  private let writerDrainTimeout: Duration = .seconds(5)
  private let stopDrainTimeout: Duration = .seconds(6)

  private enum WriterDrainOutcome: Sendable {
    case signaled
    case targetSatisfied
    case timedOut
  }

  private nonisolated func isDrainSatisfiedByTarget(_ session: WriterSession) -> Bool {
    let target = session.control.targetSampleTime.load(ordering: .relaxed)
    let written = session.control.writtenSampleTime.load(ordering: .relaxed)
    let stopRequested = session.control.stopRequested.load(ordering: .relaxed)
    return stopRequested && written >= target
  }

  private nonisolated func awaitWriterDrainOutcome(_ session: WriterSession) async -> WriterDrainOutcome {
    log.info("🧹 awaitWriterDrain start for \(session.fileURL.lastPathComponent, privacy: .public)")
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: writerDrainTimeout)
    while clock.now < deadline {
      if Task.isCancelled {
        log.warning("🧹 awaitWriterDrain cancelled for \(session.fileURL.lastPathComponent, privacy: .public)")
        return .timedOut
      }
      if await session.control.drainSignal.isSignaledValue() {
        log.info("🧹 awaitWriterDrain completed for \(session.fileURL.lastPathComponent, privacy: .public)")
        return .signaled
      }
      if isDrainSatisfiedByTarget(session) {
        return .targetSatisfied
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return isDrainSatisfiedByTarget(session) ? .targetSatisfied : .timedOut
  }

  private struct InternalState {
    var recordingWriter: RecordingFileWriter?
    var recordingURL: URL?
    var recordingConfiguration: RecordingConfiguration?
    var playbackInstance: PlaybackInstance?
    var installedTapBus: Int?
    var audioBuffers: [RingBuffer<Float>]?
    var isHandlingRouteChange: Bool = false
    var initialInputFormat: AVAudioFormat?
    var lastInputFormat: AVAudioFormat?
  }
  private let state: Synchronized<InternalState> = .init(.init())

  private nonisolated func placeState<T>(_ path: WritableKeyPath<InternalState, T>, _ field: T) {
    state.withLock { $0[keyPath: path] = field }
  }

  /// A Boolean value that indicates whether the engine is currently recording.
  @MainActor public private(set) var isRecording: Bool = false

  /// The user's desired recording state.
  ///
  /// When set via ``setDesiredRecordingState(_:configuration:)``, the engine will
  /// attempt to reconcile this with the actual ``isRecording`` state for the
  /// configured timeout period. If reconciliation fails, this property is
  /// automatically set back to match ``isRecording``.
  @MainActor public private(set) var wantsRecording: Bool = false

  /// Configuration for state reconciliation attempts.
  @MainActor public var reconciliationConfiguration: ReconciliationConfiguration = .default

  /// Preferred audio session category/mode/options for this engine.
  @MainActor public var sessionConfiguration: AudioSessionConfiguration = .recorderDefault
  /// Backend used for audio file writing.
  @MainActor private var writerBackend: WriterBackend = .extAudioFile
  /// Whether the engine should deactivate the audio session when it becomes idle.
  ///
  /// Leave this `false` when a higher-level manager owns session lifecycle.
  @MainActor public var deactivateAudioSessionOnStop: Bool = false

  @MainActor private var lastRecordingConfiguration: RecordingConfiguration?
  @MainActor private var pendingRecordingRestart: RecordingConfiguration?
  @MainActor private var pendingPlaybackResume: PlaybackResume?

  /// Called when the engine fails to reconcile the desired recording state
  /// with the actual state after the configured timeout.
  ///
  /// - Parameter desiredState: The state that could not be achieved.
  @MainActor public var onReconciliationFailed: (@Sendable @MainActor (Bool) -> Void)?

  @MainActor private var reconciliationTask: Task<Void, Never>? {
    willSet {
      if reconciliationTask != newValue {
        reconciliationTask?.cancel()
      }
    }
  }
  /// The current playback state, or `nil` if no audio is playing.
  @MainActor public private(set) var playback: Playback?
  /// The default interval used to refresh `playback.time` while playback is active.
  ///
  /// This is intentionally coarse by default to avoid excessive observation churn in UI.
  ///
  /// Per-playback overrides can be provided via `play(url:playbackPollingInterval:)`
  /// and `playSegment(..., playbackPollingInterval:)`.
  ///
  /// Values `<= .zero` are treated as `.seconds(0.5)`.
  @MainActor public var defaultPlaybackPollingInterval: Duration = .seconds(0.5)
  /// Called when the playback item or playback state changes (play/pause/stop), excluding time ticks.
  @MainActor public var onPlaybackStateChanged: (@Sendable @MainActor (Playback?) -> Void)?
  @MainActor private var lastPlaybackStateSignature: PlaybackStateSignature?
  /// A Boolean value that indicates whether the engine is currently playing back audio.
  @MainActor public var isPlayback: Bool {
    playback != nil
  }
  /// A Boolean value that indicates whether the player is currently playing.
  @MainActor public var isPlaying: Bool {
    playback != nil && player.isPlaying
  }

  struct PlaybackInstance: Identifiable {
    let id: UUID
    let file: AVAudioFile
    let startFrame: AVAudioFramePosition
    let pollingInterval: Duration
  }

  private struct PlaybackResume: Sendable {
    let fileURL: URL
    let time: TimeInterval
    let duration: TimeInterval
    let wasPlaying: Bool
    let pollingInterval: Duration
  }

  private struct WriteFailure: Sendable {
    let url: URL
    let error: ErrorContext
  }
  /// A struct representing the current playback state.
  public struct Playback: Sendable, Hashable, Identifiable, Codable {
    public init(
      id: UUID, file: URL, isPlaying: Bool, time: TimeInterval? = nil, duration: TimeInterval
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
    public let time: TimeInterval?
    /// The total duration of the file in seconds.
    public let duration: TimeInterval
  }

  @MainActor
  private struct PlaybackStateSignature: Equatable {
    let id: UUID?
    let file: URL?
    let isPlaying: Bool

    init(playback: Playback?) {
      self.id = playback?.id
      self.file = playback?.file
      self.isPlaying = playback?.isPlaying ?? false
    }
  }

  @MainActor
  private func setPlayback(_ new: Playback?) {
    let previousSignature = PlaybackStateSignature(playback: playback)

    let updated: Playback?
    if let playbackInstance = state.playbackInstance, new?.id == playbackInstance.id {
      updated = new
    } else if new == nil {
      updated = nil
    } else {
      // Ignore stale updates for a previous playback instance.
      updated = playback
    }

    playback = updated

    let newSignature = PlaybackStateSignature(playback: playback)
    if previousSignature != newSignature, lastPlaybackStateSignature != newSignature {
      lastPlaybackStateSignature = newSignature
      onPlaybackStateChanged?(playback)
    }
  }

  private func getPlayback() -> Playback? {
    guard let playbackInstance = state.playbackInstance else { return nil }
    return getPlayback(for: playbackInstance)
  }

  private func getPlayback(for instance: PlaybackInstance) -> Playback {
    let startOffset =
      Double(instance.startFrame) / instance.file.processingFormat.sampleRate

    guard let nodeTime = player.lastRenderTime,
      let playerTime = player.playerTime(forNodeTime: nodeTime)
    else {
      return Playback(
        id: instance.id,
        file: instance.file.url,
        isPlaying: player.isPlaying,
        time: startOffset,
        duration: Double(instance.file.length) / instance.file.processingFormat.sampleRate
      )
    }

    let sampleRate = playerTime.sampleRate
    let timeInPlayer = Double(playerTime.sampleTime) / sampleRate
    let currentTime = timeInPlayer + startOffset

    let duration = Double(instance.file.length) / instance.file.processingFormat.sampleRate

    return Playback(
      id: instance.id,
      file: instance.file.url,
      isPlaying: player.isPlaying,
      time: currentTime,
      duration: duration
    )
  }

  @MainActor private var writerSession: WriterSession?
  @MainActor private var drainingWriterSessions: [WriterSession] = []
  @MainActor private var lastWriteFailure: WriteFailure?

  @MainActor private var playbackTask: Task<Void, Never>? {
    willSet {
      if playbackTask != newValue {
        playbackTask?.cancel()
      }
    }
  }
  @MainActor private var scrubTask: Task<Void, Never>? {
    willSet {
      if scrubTask != newValue {
        scrubTask?.cancel()
      }
    }
  }

  struct Cache {
    var cachedTapConverter: AVAudioConverter?
    var cachedConverterInputFormat: AVAudioFormat?
    var cachedConverterOutputFormat: AVAudioFormat?
    var cachedConvertedBuffer: AVAudioPCMBuffer?
  }

  private let cache: Mut<Cache> = .init(.init())
  public let bufferReceivers: Synchronized<[any BufferReceiver<Float>]> = .init([])

  //  public var eventHandler: (@Sendable (AIO.Event.Interruption) -> Void)?

  let errorSubject: Subject<any Error> = .init()

  /// An asynchronous stream of errors that occur in the audio engine.
  public var errors: AsyncBroadcaster<any Error> {
    errorSubject.broadcaster
  }

  /// Creates a new instance of the audio engine.
  public init() {
    runOnEngineControlQueue { [engine, player] in
      engine.attach(player)
    }
  }

  /// Creates a new instance of the audio engine with custom reconciliation configuration.
  ///
  /// - Parameter reconciliationConfiguration: Configuration for state reconciliation.
  @MainActor public init(reconciliationConfiguration: ReconciliationConfiguration) {
    self.reconciliationConfiguration = reconciliationConfiguration
    runOnEngineControlQueue { [engine, player] in
      engine.attach(player)
    }
  }

  // MARK: - Recording State Management

  /// Sets the desired recording state and attempts to reconcile it with the actual state.
  ///
  /// This method manages the recording lifecycle with automatic retry logic.
  /// When requesting to start recording, the engine will repeatedly attempt
  /// to warm up and start until either:
  /// - Recording starts successfully
  /// - The reconciliation timeout expires
  /// - A non-transient error occurs
  ///
  /// When requesting to stop recording, the engine stops immediately.
  ///
  /// - Parameters:
  ///   - desiredState: Whether recording should be active.
  ///   - configuration: The recording configuration to use when starting.
  ///                    Required when `desiredState` is `true`.
  @MainActor
  public func setDesiredRecordingState(
    _ desiredState: Bool,
    configuration: RecordingConfiguration? = nil
  ) {
    wantsRecording = desiredState
    reconciliationTask = nil

    if desiredState {
      guard let configuration else {
        log.error("Cannot start recording without configuration")
        wantsRecording = false
        return
      }
      lastRecordingConfiguration = configuration
      reconciliationTask = Task { @MainActor [weak self] in
        await self?.reconcileRecordingState(desiredState: true, configuration: configuration)
      }
    } else {
      // Stop immediately
      if isRecording {
        Task { @MainActor [weak self] in
          _ = try? await self?.stopRecording()
        }
      }
    }
  }

  /// Starts recording with automatic reconciliation and returns when complete.
  ///
  /// This is a convenience method that combines setting the desired state and
  /// waiting for reconciliation to complete. Use this when you need to know
  /// whether recording started successfully.
  ///
  /// - Parameter configuration: The recording configuration to use.
  /// - Returns: `true` if recording started successfully, `false` if reconciliation
  ///            failed after the timeout period or a non-transient error occurred.
  @MainActor
  public func startRecordingWithReconciliation(
    configuration: RecordingConfiguration
  ) async -> Bool {
    wantsRecording = true
    reconciliationTask = nil
    lastRecordingConfiguration = configuration
    await reconcileRecordingState(desiredState: true, configuration: configuration)
    return isRecording
  }

  /// Stops recording.
  ///
  /// This is a convenience method that sets the desired state to false
  /// and waits for the recording to stop.
  ///
  /// - Returns: The URL of the recorded file, or `nil` if not recording.
  @MainActor
  public func stopRecordingWithReconciliation() async -> URL? {
    wantsRecording = false
    reconciliationTask = nil
    guard isRecording else { return nil }
    return try? await stopRecording()
  }

  /// Attempts to reconcile the desired recording state with the actual state.
  @MainActor
  private func reconcileRecordingState(
    desiredState: Bool,
    configuration: RecordingConfiguration
  ) async {
    guard desiredState else { return }

    let startTime = ContinuousClock.now
    let timeout = reconciliationConfiguration.timeout
    let retryInterval = reconciliationConfiguration.retryInterval

    log.info(
      "Starting recording reconciliation (timeout: \(timeout, privacy: .public), interval: \(retryInterval, privacy: .public))"
    )

    var lastError: (any Error)?

    while !Task.isCancelled && wantsRecording {
      let elapsed = ContinuousClock.now - startTime

      // Check if we've exceeded the timeout
      if elapsed >= timeout {
        log.warning(
          "Recording reconciliation timed out after \(elapsed, privacy: .public)"
        )
        break
      }

      do {
        // Attempt to start recording
        try await startRecording(configuration: configuration)

        // Success!
        log.info("Recording started successfully after \(elapsed, privacy: .public)")
        return
      } catch let error where error.isTransient {
        // Transient error - wait and retry
        lastError = error
        log.info(
          "Transient error during reconciliation: \(error, privacy: .public), retrying..."
        )
        try? await Task.sleep(for: retryInterval)
        continue
      } catch {
        // Non-transient error - give up immediately
        log.error(
          "Non-transient error during reconciliation: \(error, privacy: .public)"
        )
        lastError = error
        break
      }
    }

    // Reconciliation failed - reset desired state to match actual
    if wantsRecording && !isRecording {
      log.warning(
        "Reconciliation failed, resetting wantsRecording to false. Last error: \(lastError?.localizedDescription ?? "none", privacy: .public)"
      )
      wantsRecording = false
      onReconciliationFailed?(true)
    }
  }

  /// Starts recording audio with the specified configuration.
  ///
  /// This method first stops any active playback and then warms up the engine with the provided configuration.
  /// Once the engine is ready, it starts recording audio to a temporary file.
  ///
  /// - Parameter configuration: The configuration to use for recording.
  /// - Throws: An `AIOError` if the recording configuration is invalid or if the engine fails to start.
  public nonisolated func startRecording(
    configuration: RecordingConfiguration
  ) async throws(AIOError) {
    do {
      let shouldClearPlayback = await withEngineControlQueue { [weak self] in
        guard let self else { return false }
        return self.player.isPlaying
      }
      if shouldClearPlayback {
        await stopPlayerIfNeeded()
      }
      try await MainActor.run {
        // Stop any active playback before recording
        if shouldClearPlayback {
          placeState(\.playbackInstance, nil)
          playback = nil
        }
        lastWriteFailure = nil
        lastRecordingConfiguration = configuration
        try warm(configuration: configuration)

        let (buffers, writer, url) = state { ($0.audioBuffers, $0.recordingWriter, $0.recordingURL) }
        guard let buffers = buffers,
          let processingFormat = configuration.processingFormat,
          let writeWriter = writer,
          let url = url
        else {
          throw AIOError.invalidRecordingConfiguration(
            details: "state after warm(configuration:) was invalid")
        }
        let startResult = runOnEngineControlQueueResult { [weak self] in
          guard let self else { return }
          try self.engine.start()
        }
        if case .failure(let error) = startResult {
          throw AIOError.engineStartFailed(error: ErrorContext(error))
        }
        let fileFormat = configuration.outputConfiguration.fileFormat.rawValue
        onRecordingStarted?(url, fileFormat)
        startFileWriteLoop(flushing: buffers, of: processingFormat, to: writeWriter)
        self.isRecording = true
      }
    } catch let error as AIOError {
      throw error
    } catch {
      throw .engineStartFailed(error: ErrorContext(error))
    }
  }

  @MainActor private func startFileWriteLoop(
    flushing buffers: [RingBuffer<Float>],
    of processingFormat: AVAudioFormat,
    to writer: RecordingFileWriter
  ) {
    let control = WriterControl()
    let errorHandler: @Sendable (ErrorContext) -> Void = { [weak self] error in
      guard let self else { return }
      Task { @MainActor in
        self.recordWriteFailure(error, url: writer.fileURL)
        self.errorSubject.send(
          AIOError.audioFileFailed(operation: .write, url: writer.fileURL, error: error)
        )
        self.onRecordingFailed?()
      }
    }
    let session = WriterSession(
      id: UUID(),
      control: control,
      writer: writer,
      fileURL: writer.fileURL
    )
    writerSession = session
    writerQueue.async { [control] in
      AIOEngine.writerLoopSync(
        writer: writer,
        format: processingFormat,
        audioBuffers: buffers,
        control: control,
        shouldCancel: { [control] in
          control.cancelRequested.load(ordering: .relaxed)
        },
        errorHandler: errorHandler
      )
    }
    log.info("📝 Writer started for \(writer.fileURL.lastPathComponent, privacy: .public)")

  }

  @MainActor
  private func prepareDrain(for session: WriterSession, targetSampleTime: Int64, logBuffers: Bool) {
    session.control.stopRequested.store(true, ordering: .relaxed)
    session.control.targetSampleTime.store(targetSampleTime, ordering: .relaxed)
    if logBuffers {
      let counts = state.withLock { $0.audioBuffers?.map { $0.count } ?? [] }
      let written = session.control.writtenSampleTime.load(ordering: .relaxed)
      log.info(
        "🧹 Stop target set: target=\(targetSampleTime, privacy: .public) written=\(written, privacy: .public) buffers=\(counts, privacy: .public)"
      )
    } else {
      log.info(
        "🧹 Stop target set: target=\(targetSampleTime, privacy: .public) (non-current session)"
      )
    }
  }

  @MainActor
  private func drainWriterSession(_ session: WriterSession, notifyOnFailure: Bool) async {
    let clock = ContinuousClock()
    let start = clock.now
    log.info("🧹 Drain start for \(session.fileURL.lastPathComponent, privacy: .public)")
    let outcome = await awaitWriterDrainOutcome(session)
    let elapsed = start.duration(to: clock.now)
    switch outcome {
    case .signaled:
      session.writer.close()
      let size = fileSizeDescription(for: session.fileURL)
      log.info(
        "🧹 Writer drained for \(session.fileURL.lastPathComponent, privacy: .public) (size=\(size, privacy: .public), elapsed=\(elapsed, privacy: .public))"
      )
    case .targetSatisfied:
      session.control.cancelRequested.store(true, ordering: .relaxed)
      session.writer.close()
      let target = session.control.targetSampleTime.load(ordering: .relaxed)
      let written = session.control.writtenSampleTime.load(ordering: .relaxed)
      log.info(
        "🧹 Drain short-circuit: target satisfied for \(session.fileURL.lastPathComponent, privacy: .public) target=\(target, privacy: .public) written=\(written, privacy: .public) elapsed=\(elapsed, privacy: .public)"
      )
    case .timedOut:
      let error = WriterDrainTimeoutError(url: session.fileURL, timeout: writerDrainTimeout)
      session.control.cancelRequested.store(true, ordering: .relaxed)
      session.writer.close()
      let target = session.control.targetSampleTime.load(ordering: .relaxed)
      let written = session.control.writtenSampleTime.load(ordering: .relaxed)
      log.error(
        "⏱️ Writer drain timed out for \(session.fileURL.lastPathComponent, privacy: .public) after \(elapsed, privacy: .public): \(error, privacy: .public) target=\(target, privacy: .public) written=\(written, privacy: .public)"
      )
      recordWriteFailure(ErrorContext(error), url: session.fileURL)
      if notifyOnFailure {
        errorSubject.send(
          AIOError.audioFileFailed(
            operation: .write,
            url: session.fileURL,
            error: ErrorContext(error)
          )
        )
        onRecordingFailed?()
      }
    }
  }

  @MainActor
  private func enqueueDrain(for session: WriterSession) {
    let target = recordingSampleTimeAtomic.load(ordering: .relaxed)
    prepareDrain(for: session, targetSampleTime: target, logBuffers: session.id == writerSession?.id)
    drainingWriterSessions.append(session)
    Task { [weak self] in
      guard let self else { return }
      await self.drainWriterSession(session, notifyOnFailure: true)
      await MainActor.run { self.drainingWriterSessions.removeAll { $0.id == session.id } }
    }
  }

  @MainActor
  private func stopAndDrainAllWriterSessions(notifyOnFailure: Bool) async {
    if Task.isCancelled {
      log.warning("🧹 stopAndDrainAllWriterSessions cancelled before start")
      return
    }
    var sessions: [WriterSession] = []
    if let current = writerSession {
      sessions.append(current)
    }
    sessions.append(contentsOf: drainingWriterSessions)

    let target = recordingSampleTimeAtomic.load(ordering: .relaxed)
    for session in sessions {
      if Task.isCancelled {
        log.warning("🧹 stopAndDrainAllWriterSessions cancelled before stop request")
        return
      }
      log.info("🧹 Stop requested for writer \(session.fileURL.lastPathComponent, privacy: .public)")
      prepareDrain(for: session, targetSampleTime: target, logBuffers: session.id == writerSession?.id)
    }
    for session in sessions {
      if Task.isCancelled {
        log.warning("🧹 stopAndDrainAllWriterSessions cancelled before drain wait")
        return
      }
      log.info("🧹 Drain wait start for \(session.fileURL.lastPathComponent, privacy: .public)")
      await drainWriterSession(session, notifyOnFailure: notifyOnFailure)
    }

    writerSession = nil
    drainingWriterSessions.removeAll()
    log.info("🧹 stopAndDrainAllWriterSessions completed")
  }

  @MainActor
  private func cancelAllWriterSessions() {
    if let current = writerSession {
      current.control.cancelRequested.store(true, ordering: .relaxed)
    }
    for session in drainingWriterSessions {
      session.control.cancelRequested.store(true, ordering: .relaxed)
    }
    writerSession = nil
    drainingWriterSessions.removeAll()
    log.info("🧹 cancelAllWriterSessions completed")
  }

  @MainActor
  private func recordWriteFailure(_ error: ErrorContext, url: URL) {
    guard lastWriteFailure == nil else { return }
    lastWriteFailure = WriteFailure(url: url, error: error)
    log.error(
      "🛑 Recording write failed for \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)"
    )
  }

  @MainActor
  private func consumeWriteFailure() -> WriteFailure? {
    defer { lastWriteFailure = nil }
    return lastWriteFailure
  }

  /// Warms up the audio engine with the specified configuration.
  ///
  /// This method prepares the audio engine for recording by configuring the audio session,
  /// setting up the necessary buffers, and installing an audio tap.
  ///
  /// - Parameter configuration: The configuration to use for recording.
  /// - Throws: An `AIOError` if the configuration is invalid or if the engine fails to warm up.
  @MainActor
  public func warm(configuration: RecordingConfiguration) throws(AIOError) {
    guard !isRecording && !isPlaying else {
      return
    }
    log.info("warming with config: \(configuration, privacy: .public)")
    let initialInput = runOnEngineControlQueue { engine.inputNode.outputFormat(forBus: 0) }
    log.info("input format: \(initialInput, privacy: .public)")
    if let recordingConfiguration = state.recordingConfiguration {
      if configuration == recordingConfiguration {
        log.info("engine already warmed")
        recordingSampleTimeAtomic.store(0, ordering: .relaxed)
        return
      } else {
        log.info("engine requires hard stop")
        // TODO: reconfigure active recording instead
        hardStop()
      }
    }
    log.info("engine requires warming")
    do {

      // Configure audio session
      try configureAudioSession(for: configuration)

      let (url, protection) = try resolveOutputURL(
        for: configuration,
        allowExplicitFile: true
      )

      let writer = try makeRecordingWriter(url: url, configuration: configuration)
      applyFileProtectionIfNeeded(protection, to: url)

      let inputFormat = runOnEngineControlQueue { engine.inputNode.outputFormat(forBus: 0) }

      // Validate input format before attempting to install tap.
      // installTap throws an uncatchable NSException if the format is invalid.
      guard inputFormat.channelCount > 0 else {
        let session = AVAudioSession.sharedInstance()
        let hardwareFormat = runOnEngineControlQueue { engine.inputNode.inputFormat(forBus: 0) }
        let recordPermission = AVAudioApplication.shared.recordPermission
        log.warning(
          """
          Input node has no channels; audio input not ready.
          recordPermission: \(String(describing: recordPermission), privacy: .public)
          isInputAvailable: \(session.isInputAvailable, privacy: .public)
          outputFormat(forBus: 0): \(inputFormat, privacy: .public)
          inputFormat(forBus: 0): \(hardwareFormat, privacy: .public)
          """
        )
        throw AIOError.audioSessionNotReady(
          details: "Input node has no channels (channelCount: 0)"
        )
      }
      guard inputFormat.sampleRate > 0 else {
        let session = AVAudioSession.sharedInstance()
        let hardwareFormat = runOnEngineControlQueue { engine.inputNode.inputFormat(forBus: 0) }
        let recordPermission = AVAudioApplication.shared.recordPermission
        log.warning(
          """
          Input node has invalid sample rate; audio input not ready.
          recordPermission: \(String(describing: recordPermission), privacy: .public)
          isInputAvailable: \(session.isInputAvailable, privacy: .public)
          outputFormat(forBus: 0): \(inputFormat, privacy: .public)
          inputFormat(forBus: 0): \(hardwareFormat, privacy: .public)
          """
        )
        throw AIOError.audioSessionNotReady(
          details: "Input node has invalid sample rate (sampleRate: 0)"
        )
      }

      guard let processingFormat = configuration.processingFormat else {
        throw AIOError.invalidRecordingConfiguration(details: "(processing format)")
      }

      // Setup ring buffers with overflow protection
      let sampleRate = Int(processingFormat.sampleRate)
      let channelCount = Int(processingFormat.channelCount)

      // Validate sample rate and channel count
      // Note: Zero or negative values often indicate the audio session isn't ready yet
      guard sampleRate > 0 && channelCount > 0 else {
        log.warning(
          "Audio format not ready: sampleRate=\(sampleRate, privacy: .public), channelCount=\(channelCount, privacy: .public)"
        )
        throw AIOError.audioSessionNotReady(
          details: "Invalid format: \(sampleRate)Hz, \(channelCount)ch"
        )
      }

      // Protect against overflow in buffer capacity calculation
      guard sampleRate < Int.max / channelCount / 2 else {
        log.error(
          "Sample rate too high for buffer allocation: sampleRate=\(sampleRate, privacy: .public), channelCount=\(channelCount, privacy: .public)"
        )
        throw AIOError.hardwareNotSupported
      }

      let audioBuffers = Self.makeAudioBuffers(
        sampleRate: sampleRate,
        channelCount: channelCount
      )

      guard let tapConfiguration = configuration.tapConfiguration(bus: 0, input: inputFormat)
      else {
        throw AIOError.invalidRecordingConfiguration(details: "(Tap configuration)")
      }
      guard tapConfiguration.bufferSize > 0 else {
        throw AIOError.invalidRecordingConfiguration(details: "Tap bufferSize is 0")
      }
      // Defensive: ensure we never double-install a tap if state got out of sync.
      runOnEngineControlQueue {
        engine.inputNode.removeTap(onBus: tapConfiguration.bus)
      }
      recordingSampleTimeAtomic.store(0, ordering: .relaxed)
      // Install tap
      runOnEngineControlQueue {
        engine.inputNode.installTap(
          onBus: tapConfiguration.bus,
          bufferSize: tapConfiguration.bufferSize,
          format: tapConfiguration.inputAVAudioFormat
        ) { @Sendable [bufferReceivers] buffer, time in
          self.processAudio(
            buffer: buffer,
            time: time,
            to: processingFormat,
            bufferReceivers: bufferReceivers
          )
        }
        engine.prepare()
      }

      state {
        $0.recordingWriter = writer
        $0.recordingURL = url
        $0.audioBuffers = audioBuffers
        $0.installedTapBus = tapConfiguration.bus
        $0.recordingConfiguration = configuration
        $0.initialInputFormat = inputFormat
        $0.lastInputFormat = inputFormat
      }
    } catch let error as AIOError {
      log.error(
        "Failed to warm engine: \(error, privacy: .public)"
      )
      hardStop()
      onRecordingFailed?()
      throw error
    } catch {
      let mapped = AIOError.engineStartFailed(error: ErrorContext(error))
      log.error("Failed to warm engine: \(mapped, privacy: .public)")
      hardStop()
      onRecordingFailed?()
      throw mapped
    }
  }

  private static func makeAudioBuffers(
    sampleRate: Int,
    channelCount: Int
  ) -> [RingBuffer<Float>] {
    (0..<channelCount).map { _ in
      RingBuffer<Float>(capacity: sampleRate * channelCount * 2)  // 2 seconds of buffer
    }
  }

  @MainActor private func hardStop() {
    let tapBus = state.consume(\.installedTapBus)
    runOnEngineControlQueue { [weak self] in
      guard let self else { return }
      if let tapBus {
        self.engine.inputNode.removeTap(onBus: tapBus)
      }
      if self.engine.isRunning {
        self.engine.stop()
      }
      if self.player.isPlaying {
        self.player.stop()
      }
      // On iOS 26.x, explicit `disconnectNodeOutput(_:)` has been observed to occasionally
      // raise an uncatchable NSException after background transitions; prefer `reset()`.
      self.engine.reset()
    }
    let hasActiveWriter = writerSession != nil || !drainingWriterSessions.isEmpty
    if let current = writerSession {
      enqueueDrain(for: current)
      writerSession = nil
    }
    cleanUp(closeFile: !hasActiveWriter)
  }

  @MainActor
  private func gracefulStop() async {
    let tapBus = state.consume(\.installedTapBus)
    log.info("🛑 gracefulStop starting (tapBus=\(String(describing: tapBus), privacy: .public))")
    engineControlQueue.async { [weak self] in
      guard let self else { return }
      log.info("🛑 gracefulStop engine stop enqueued")
      if let tapBus = tapBus {
        self.engine.inputNode.removeTap(onBus: tapBus)
      }
      self.engine.stop()
    }
    log.info("🛑 gracefulStop draining writer sessions")
    let drainCompleted = await withTaskGroup(of: Bool.self) { group in
      group.addTask { [self] in
        await self.stopAndDrainAllWriterSessions(notifyOnFailure: false)
        return true
      }
      group.addTask { [self] in
        try? await Task.sleep(for: self.stopDrainTimeout)
        return false
      }
      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }
    if !drainCompleted {
      let url = state.recordingURL ?? URL(fileURLWithPath: "unknown")
      let error = WriterDrainTimeoutError(url: url, timeout: stopDrainTimeout)
      log.error("⏱️ stopAndDrainAllWriterSessions timed out: \(error, privacy: .public)")
      cancelAllWriterSessions()
      recordWriteFailure(ErrorContext(error), url: url)
    }
    log.info("🛑 gracefulStop cleanup starting")
    cleanUp()
    isRecording = false
    wantsRecording = false
    reconciliationTask = nil
    log.info("🛑 gracefulStop completed")
    deactivateAudioSessionIfNeeded(reason: "recording stopped")
  }

  @MainActor private func cleanUp(closeFile: Bool = true) {
    let writer = state { state in
      defer {
        state.recordingWriter = nil
        state.recordingURL = nil
        state.recordingConfiguration = nil
        state.audioBuffers = nil
        state.initialInputFormat = nil
        state.lastInputFormat = nil
        state.isHandlingRouteChange = false
      }
      return state.recordingWriter
    }
    if closeFile {
      writer?.close()
    }
    cache.withLock { c in
      c.cachedTapConverter = nil
      c.cachedConverterInputFormat = nil
      c.cachedConverterOutputFormat = nil
      c.cachedConvertedBuffer = nil
    }
    playbackTask = nil
  }

  nonisolated private func processAudio(
    buffer: AVAudioPCMBuffer,
    time: AVAudioTime?,
    to processingFormat: AVAudioFormat,
    bufferReceivers: Synchronized<[any BufferReceiver<Float>]>
  ) {
    let frameLength = buffer.frameLength
    guard frameLength > 0 else { return }

    let converter: AVAudioConverter
    let (
      cachedTapConverter,
      cachedConverterInputFormat,
      cachedConverterOutputFormat
    ) = cache.withLock { c in
      (
        c.cachedTapConverter,
        c.cachedConverterInputFormat,
        c.cachedConverterOutputFormat
      )
    }
    if let cachedConverter = cachedTapConverter,
      let inputFormat = cachedConverterInputFormat,
      let outputFormat = cachedConverterOutputFormat,
      inputFormat.isEqual(buffer.format),
      outputFormat.isEqual(processingFormat)
    {
      converter = cachedConverter
    } else {
      log.info(
        """
            No cached converter available for buffer. One will be created.
            input buffer: \(buffer.format, privacy: .public)
            cached input converter: \(cachedConverterInputFormat, privacy: .public)
            cached output converter: \(cachedConverterOutputFormat, privacy: .public)
            processingFormat: \(processingFormat, privacy: .public)
        """)
      guard let newConverter = AVAudioConverter(from: buffer.format, to: processingFormat) else {
        let error = AIOError.formatConversionFailed
        log.error("Failed to create audio converter: \(error, privacy: .public)")
        errorSubject.send(error)
        return
      }
      cache.withLock { c in
        c.cachedTapConverter = newConverter
        c.cachedConverterInputFormat = buffer.format
        c.cachedConverterOutputFormat = processingFormat
      }
      converter = newConverter
    }

    // When the hardware sample rate differs from our processing format, the converter
    // needs enough output capacity to perform the resampling. Using the input frame
    // length here starves up/downsampling (e.g., 28kHz→48kHz) and produces distorted
    // audio. Calculate the required frames based on the sample-rate ratio instead.
    let frameRatio = processingFormat.sampleRate / buffer.format.sampleRate
    let requestedCapacity = max(
      AVAudioFrameCount(ceil(Double(frameLength) * frameRatio)),
      1
    )
    let convertedBuffer: AVAudioPCMBuffer? = cache.withLock({
      if let cachedBuffer = $0.cachedConvertedBuffer,
        cachedBuffer.format.isEqual(processingFormat),
        cachedBuffer.frameCapacity >= requestedCapacity
      {
        return cachedBuffer
      } else {
        let newBuffer = AVAudioPCMBuffer(
          pcmFormat: processingFormat,
          frameCapacity: requestedCapacity
        )
        $0.cachedConvertedBuffer = newBuffer
        return newBuffer
      }
    })

    guard let convertedBuffer else {
      return
    }
    convertedBuffer.frameLength = requestedCapacity

    var error: NSError? = nil
    let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
      outStatus.pointee = .haveData
      return buffer
    }
    guard status != .error else {
      let error = error ?? NSError(domain: "unknown", code: 666)
      errorSubject.send(error)
      return
    }

    guard let audioBuffers = state.withLock({ $0.audioBuffers }) else {
      return
    }

    // Enqueue to ring buffers
    let channelCount = Int(convertedBuffer.format.channelCount)
    guard channelCount <= audioBuffers.count else {
      log.error(
        "Channel count mismatch: \(channelCount, privacy: .public) vs \(audioBuffers.count, privacy: .public)"
      )
      return
    }

    let processingStartSampleTime = recordingSampleTimeAtomic.load(ordering: .relaxed)
    let sourceHostTime: UInt64? =
      (time?.isHostTimeValid ?? false) ? time?.hostTime : nil
    let sourceSampleTime: Int64? =
      (time?.isSampleTimeValid ?? false) ? time.map { Int64($0.sampleTime) } : nil
    let sourceSampleRate: Double? =
      (time?.isSampleTimeValid ?? false) ? time?.sampleRate : nil
    let receiverTiming = BufferTiming(
      sampleTime: processingStartSampleTime,
      sampleRate: processingFormat.sampleRate,
      hostTime: sourceHostTime,
      sourceSampleTime: sourceSampleTime,
      sourceSampleRate: sourceSampleRate
    )

    for i in 0..<channelCount {
      guard let channelData = convertedBuffer.floatChannelData?[i] else {
        log.error(
          "Failed to access channel data for channel \(i, privacy: .public)"
        )
        continue
      }
      let frameLength = Int(convertedBuffer.frameLength)
      audioBuffers[i].write(UnsafeBufferPointer(start: channelData, count: frameLength))

      // Feed data to visualization engine (non-blocking)
      if i == 0 {
        bufferReceivers({ $0 }).forEach {
          $0.processBuffer(
            UnsafeBufferPointer(start: channelData, count: frameLength),
            timing: receiverTiming
          )
        }
      }
    }

    recordingSampleTimeAtomic.wrappingIncrement(
      by: Int64(convertedBuffer.frameLength),
      ordering: .relaxed
    )
  }

  private static func writerLoopSync(
    writer: RecordingFileWriter,
    format: AVAudioFormat,
    audioBuffers: [RingBuffer<Float>],
    control: WriterControl,
    shouldCancel: @escaping @Sendable () -> Bool,
    errorHandler: @escaping @Sendable (ErrorContext) -> Void
  ) {
    let bufferSize = 1024  // Write in chunks
    let clock = ContinuousClock()
    var stopRequestedAt: ContinuousClock.Instant?
    var lastStallLog = clock.now
    var writtenSampleTime: Int64 = 0

    while true {
      if shouldCancel() { break }
      let result = flushChunk(
        size: bufferSize,
        from: audioBuffers,
        in: format,
        to: writer
      )
      switch result {
      case .success(let writeResult):
        let framesRead = writeResult.framesRead
        let didWrite = writeResult.writeDuration != nil
        if didWrite, framesRead > 0 {
          writtenSampleTime &+= Int64(framesRead)
          control.writtenSampleTime.store(writtenSampleTime, ordering: .relaxed)
        }
        let stopRequested = control.stopRequested.load(ordering: .relaxed)
        if stopRequested {
          let target = control.targetSampleTime.load(ordering: .relaxed)
          if writtenSampleTime >= target {
            break
          }
        }
        if framesRead == 0 {
          if stopRequested, stopRequestedAt == nil {
            stopRequestedAt = clock.now
            log.info(
              "🧹 Writer stop requested: target=\(control.targetSampleTime.load(ordering: .relaxed), privacy: .public) written=\(writtenSampleTime, privacy: .public) file=\(writer.fileURL.lastPathComponent, privacy: .public)"
            )
          }
          if stopRequested,
            minimumAvailableFrames(
              channelCount: Int(format.channelCount),
              audioBuffers: audioBuffers,
              limit: bufferSize
            ) == 0
          {
            break
          }
          if stopRequested {
            let target = control.targetSampleTime.load(ordering: .relaxed)
            if writtenSampleTime >= target {
              break
            }
          }
          if stopRequested, let stopRequestedAt {
            let elapsed = stopRequestedAt.duration(to: clock.now)
            if elapsed > .seconds(1), lastStallLog.duration(to: clock.now) > .seconds(1) {
              lastStallLog = clock.now
              let counts = audioBuffers.map { $0.count }
              let minAvail = minimumAvailableFrames(
                channelCount: Int(format.channelCount),
                audioBuffers: audioBuffers,
                limit: bufferSize
              )
              log.warning(
                "🧹 Writer stall after stop: elapsed=\(elapsed, privacy: .public) minAvail=\(minAvail, privacy: .public) counts=\(counts, privacy: .public)"
              )
            }
          }
          if shouldCancel() { break }
          Thread.sleep(forTimeInterval: 0.001)
        }
      case .failure(let error):
        let context = ErrorContext(error)
        errorHandler(context)
        break
      }
    }
    log.info("🧹 writerLoop exiting for \(writer.fileURL.lastPathComponent, privacy: .public)")
    Task { await control.drainSignal.signal() }
  }

  private struct WriteResult: Sendable {
    let framesRead: Int
    let writeDuration: Duration?
  }

  private static func flushChunk(
    size bufferSize: Int,
    from audioBuffers: [RingBuffer<Float>],
    in audioFormat: AVAudioFormat,
    to writer: RecordingFileWriter
  ) -> Result<WriteResult, Error> {
    let channelCount = Int(audioFormat.channelCount)
    let framesToRead = minimumAvailableFrames(
      channelCount: channelCount,
      audioBuffers: audioBuffers,
      limit: bufferSize
    )

    guard framesToRead > 0 else {
      return .success(.init(framesRead: 0, writeDuration: nil))
    }

    guard
      let pcmBuffer = AVAudioPCMBuffer(
        pcmFormat: audioFormat,
        frameCapacity: AVAudioFrameCount(bufferSize)
      )
    else {
      return .success(.init(framesRead: 0, writeDuration: nil))
    }

    var actualFrames = framesToRead
    // Dequeue from ring buffers using a consistent frame count per channel
    for i in 0..<channelCount {
      guard let channelData = pcmBuffer.floatChannelData?[i] else {
        actualFrames = 0
        return .success(.init(framesRead: 0, writeDuration: nil))
      }
      let readSize = audioBuffers[i].read(
        into: UnsafeMutableBufferPointer(start: channelData, count: framesToRead))
      actualFrames = min(actualFrames, readSize)
    }

    guard actualFrames > 0 else {
      return .success(.init(framesRead: 0, writeDuration: nil))
    }
    pcmBuffer.frameLength = AVAudioFrameCount(actualFrames)

    do {
      let clock = ContinuousClock()
      let start = clock.now
      try writer.write(pcmBuffer)
      let elapsed = start.duration(to: clock.now)
      if elapsed > .milliseconds(200) {
        log.warning(
          "🐢 Slow write: \(elapsed, privacy: .public) frames=\(actualFrames, privacy: .public) file=\(writer.fileURL.lastPathComponent, privacy: .public)"
        )
      }
      return .success(.init(framesRead: actualFrames, writeDuration: elapsed))
    } catch {
      log.error("error flushing chunk: \(error, privacy: .public)")
      return .failure(error)
    }
  }

  private static func minimumAvailableFrames(
    channelCount: Int,
    audioBuffers: [RingBuffer<Float>],
    limit: Int
  ) -> Int {
    guard channelCount > 0 else { return 0 }

    var minimum = limit
    for index in 0..<min(channelCount, audioBuffers.count) {
      minimum = min(minimum, audioBuffers[index].count)
      if minimum == 0 { break }
    }
    return minimum
  }

  /// Stops the current recording and returns the URL of the recorded file.
  ///
  /// - Returns: The URL of the recorded file.
  /// - Throws: An `AIOError.notRecording` error if the engine is not currently recording.
  @MainActor
  public func stopRecording() async throws(AIOError) -> URL {
    guard let url = state.recordingURL, isRecording else { throw AIOError.notRecording }
    log.info("🛑 stopRecording requested for \(url.lastPathComponent, privacy: .public)")
    await gracefulStop()
    log.info("🛑 stopRecording finished gracefulStop for \(url.lastPathComponent, privacy: .public)")
    let fileExists = FileManager.default.fileExists(atPath: url.path)
    let fileSize = fileSizeValue(for: url)
    let failure = consumeWriteFailure()
    if !fileExists {
      throw AIOError.audioFileFailed(
        operation: .write,
        url: url,
        error: ErrorContext(MissingAudioFileError(url: url))
      )
    }
    if let size = fileSize, size == 0 {
      throw AIOError.audioFileFailed(
        operation: .write,
        url: url,
        error: ErrorContext(EmptyAudioFileError(url: url))
      )
    }
    if let failure {
      if isWriterDrainTimeout(failure), fileExists, (fileSize ?? 0) > 0 {
        log.warning(
          "⚠️ Writer drain timed out but file exists with data; continuing stop for \(url.lastPathComponent, privacy: .public)"
        )
      } else {
        throw AIOError.audioFileFailed(operation: .write, url: failure.url, error: failure.error)
      }
    }
    let finalSize = fileSizeDescription(for: url)
    log.info(
      "✅ Recording stopped: \(url.lastPathComponent, privacy: .public) size=\(finalSize, privacy: .public)"
    )
    onRecordingCompleted?()
    return url
  }

  private nonisolated func isWriterDrainTimeout(_ failure: WriteFailure) -> Bool {
    failure.error.domain.contains("WriterDrainTimeoutError")
      || failure.error.message.localizedCaseInsensitiveContains("writer drain timed out")
  }

  /// Rotates the recording to a new file without interrupting audio capture.
  ///
  /// This method is used for segmented recording mode, where the recorder automatically
  /// creates new track files at specified intervals. The ring buffers continue receiving
  /// audio throughout the rotation - no samples are lost.
  ///
  /// The rotation process:
  /// 1. Creates a new output file
  /// 2. Cancels the current writer loop (it will flush remaining data)
  /// 3. Waits briefly for the writer to finish the current chunk
  /// 4. Updates state with the new file
  /// 5. Starts a new writer loop
  ///
  /// - Returns: URL of the completed (previous) recording file
  /// - Throws: `AIOError.notRecording` if not currently recording
  @MainActor
  public func rotateRecordingFile() async throws(AIOError) -> URL {
    guard isRecording,
      let currentURL = state.recordingURL,
      let configuration = state.recordingConfiguration,
      let processingFormat = configuration.processingFormat
    else {
      throw AIOError.notRecording
    }

    // Create new file with fresh filename
    let (newURL, protection) = try resolveOutputURL(
      for: configuration,
      allowExplicitFile: false
    )
    let newWriter = try makeRecordingWriter(url: newURL, configuration: configuration)
    applyFileProtectionIfNeeded(protection, to: newURL)

    let sampleRate = Int(processingFormat.sampleRate)
    let channelCount = Int(processingFormat.channelCount)
    guard sampleRate > 0, channelCount > 0 else {
      throw AIOError.invalidRecordingConfiguration(details: "Invalid processing format")
    }

    let newBuffers = Self.makeAudioBuffers(
      sampleRate: sampleRate,
      channelCount: channelCount
    )

    if let currentWriter = writerSession {
      enqueueDrain(for: currentWriter)
    } else {
      state.recordingWriter?.close()
    }

    // Update state with new file
    state.recordingWriter = newWriter
    state.recordingURL = newURL
    state.audioBuffers = newBuffers

    // Start new writer loop for the new file
    startFileWriteLoop(flushing: newBuffers, of: processingFormat, to: newWriter)

    // Notify of new file (for crash detection tracking)
    let fileFormat = configuration.outputConfiguration.fileFormat.rawValue
    onRecordingStarted?(newURL, fileFormat)

    log.info("📼 Rotated recording file to: \(newURL.lastPathComponent, privacy: .public)")

    return currentURL
  }

  /// Called when a recording segment is completed (file rotated).
  /// The handler receives the URL of the completed segment and its format.
  @MainActor public var onSegmentCompleted: (@Sendable @MainActor (URL, String) -> Void)?

  /// Plays an audio file from the specified URL.
  ///
  /// This method stops any current playback or recording before starting the new playback.
  ///
  /// - Parameter url: The URL of the audio file to play.
  /// - Returns: A `Playback` instance representing the current playback state.
  /// - Throws: An `AIOError.cannotPlayWhileRecording` error if the engine is currently recording.
  @MainActor
  public func play(url: URL) async throws(AIOError) -> Playback {
    try await play(url: url, playbackPollingInterval: nil)
  }

  /// Plays an audio file from the specified URL.
  ///
  /// This method stops any current playback or recording before starting the new playback.
  ///
  /// - Parameters:
  ///   - url: The URL of the audio file to play.
  ///   - playbackPollingInterval: Optional override for how often `playback.time` is refreshed.
  /// - Returns: A `Playback` instance representing the current playback state.
  /// - Throws: An `AIOError.cannotPlayWhileRecording` error if the engine is currently recording.
  @MainActor
  public func play(url: URL, playbackPollingInterval: Duration?) async throws(AIOError) -> Playback
  {
    // Prevent playback while recording
    guard !isRecording else {
      throw AIOError.cannotPlayWhileRecording
    }

    try configureAudioSessionForPlayback()

    if getPlayback() != nil {
      await stopAndResetEngine()
      state.playbackInstance = nil
      setPlayback(nil)
    } else {
      await stopAndResetEngine()
    }

    let file: AVAudioFile
    do {
      file = try AVAudioFile(forReading: url)
    } catch {
      throw AIOError.audioFileFailed(
        operation: .openForReading, url: url, error: ErrorContext(error))
    }
    guard file.length > 0 else {
      throw AIOError.audioFileFailed(
        operation: .openForReading,
        url: url,
        error: ErrorContext(EmptyAudioFileError(url: url))
      )
    }
    let interval =
      (playbackPollingInterval ?? defaultPlaybackPollingInterval) > .zero
      ? (playbackPollingInterval ?? defaultPlaybackPollingInterval)
      : .seconds(0.5)
    let playbackInstance = PlaybackInstance(
      id: .init(),
      file: file,
      startFrame: file.framePosition,
      pollingInterval: interval
    )

    state.playbackInstance = playbackInstance
    await withEngineControlQueue { [weak self] in
      guard let self else { return }
      // Connect the player node to the output node.
      // Note: player is already attached in init(), we only need to connect it.
      self.engine.connect(
        self.player,
        to: self.engine.outputNode,
        format: file.processingFormat
      )
      self.player
        .scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) {
          [
            weak self,
            playbackInstance
          ] _ in
          self?.cleanupPlaybackInstance(playbackInstance)
        }
    }
    let startResult = await withEngineControlQueueResult { [weak self] in
      guard let self else { return }
      try self.engine.start()
    }
    if case .failure(let error) = startResult {
      throw AIOError.engineStartFailed(error: ErrorContext(error))
    }
    let playback = getPlayback(for: playbackInstance)
    setPlayback(playback)
    await withEngineControlQueue { [weak self] in
      self?.player.play()
    }
    resetPlaybackTimer(to: playbackInstance)
    return playback
  }

  /// Plays a specific segment (time range) of an audio file.
  ///
  /// Use this for non-destructive audio editing playback, where segments of the
  /// original file are played in sequence.
  ///
  /// - Parameters:
  ///   - url: The URL of the audio file.
  ///   - startTime: Start time in seconds within the file.
  ///   - endTime: End time in seconds within the file.
  ///   - onComplete: Called when the segment finishes playing (on main actor).
  /// - Returns: A `Playback` instance representing the segment playback state.
  /// - Throws: An `AIOError.cannotPlayWhileRecording` error if currently recording.
  @MainActor
  public func playSegment(
    url: URL,
    startTime: TimeInterval,
    endTime: TimeInterval,
    onComplete: (@MainActor @Sendable () -> Void)? = nil,
    playbackPollingInterval: Duration? = nil
  ) async throws(AIOError) -> Playback {
    guard !isRecording else {
      throw AIOError.cannotPlayWhileRecording
    }

    try configureAudioSessionForPlayback()

    // Stop any existing playback
    if getPlayback() != nil {
      await stopAndResetEngine()
      state.playbackInstance = nil
      setPlayback(nil)
    } else {
      await stopAndResetEngine()
    }

    let file: AVAudioFile
    do {
      file = try AVAudioFile(forReading: url)
    } catch {
      throw AIOError.audioFileFailed(
        operation: .openForReading, url: url, error: ErrorContext(error))
    }
    let sampleRate = file.processingFormat.sampleRate
    let startFrame = AVAudioFramePosition(startTime * sampleRate)
    let duration = endTime - startTime
    let frameCount = AVAudioFrameCount(duration * sampleRate)

    // Validate frame range
    guard startFrame >= 0, frameCount > 0,
      AVAudioFramePosition(startFrame) + AVAudioFramePosition(frameCount) <= file.length
    else {
      throw AIOError.invalidTimeRange
    }

    let interval =
      (playbackPollingInterval ?? defaultPlaybackPollingInterval) > .zero
      ? (playbackPollingInterval ?? defaultPlaybackPollingInterval)
      : .seconds(0.5)
    let playbackInstance = PlaybackInstance(
      id: .init(),
      file: file,
      startFrame: startFrame,
      pollingInterval: interval
    )

    state.playbackInstance = playbackInstance

    await withEngineControlQueue { [weak self] in
      guard let self else { return }
      self.engine.connect(
        self.player,
        to: self.engine.outputNode,
        format: file.processingFormat
      )
      self.player.scheduleSegment(
        file,
        startingFrame: startFrame,
        frameCount: frameCount,
        at: nil,
        completionCallbackType: .dataPlayedBack
      ) { [weak self, playbackInstance] _ in
        self?.cleanupPlaybackInstance(playbackInstance)
        if let onComplete {
          Task { @MainActor in
            onComplete()
          }
        }
      }
    }

    let startResult = await withEngineControlQueueResult { [weak self] in
      guard let self else { return }
      try self.engine.start()
    }
    if case .failure(let error) = startResult {
      throw AIOError.engineStartFailed(error: ErrorContext(error))
    }

    let playback = getPlayback(for: playbackInstance)
    setPlayback(playback)
    await withEngineControlQueue { [weak self] in
      self?.player.play()
    }
    resetPlaybackTimer(to: playbackInstance)

    return playback
  }

  @MainActor func resetPlaybackTimer(to instance: PlaybackInstance) {
    playbackTask = Task { @MainActor in
      let interval = instance.pollingInterval
      for await _ in AsyncTimerSequence(interval: interval, clock: .suspending) {
        if Task.isCancelled { return }
        let p = getPlayback()
        if p?.id == instance.id {
          // Only update if state meaningfully changed to avoid triggering
          // unnecessary SwiftUI observation updates
          if playback?.time != p?.time || playback?.isPlaying != p?.isPlaying {
            setPlayback(p)
          }
        }
      }
    }
  }

  private nonisolated func runOnEngineControlQueue<T>(_ work: () -> T) -> T {
    engineControlQueue.sync(execute: work)
  }

  private nonisolated func runOnEngineControlQueueResult<T>(
    _ work: () throws -> T
  ) -> Result<T, Error> {
    engineControlQueue.sync {
      Result { try work() }
    }
  }

  private nonisolated func withEngineControlQueue<T>(
    _ work: @escaping @Sendable () -> T
  ) async -> T {
    await withCheckedContinuation { continuation in
      engineControlQueue.async {
        let result = work()
        continuation.resume(returning: result)
      }
    }
  }

  private nonisolated func withEngineControlQueueResult<T>(
    _ work: @escaping @Sendable () throws -> T
  ) async -> Result<T, Error> {
    await withCheckedContinuation { continuation in
      engineControlQueue.async {
        let result = Result { try work() }
        continuation.resume(returning: result)
      }
    }
  }

  private nonisolated func stopPlayerIfNeeded() async {
    await withEngineControlQueue { [weak self] in
      guard let self, self.player.isPlaying else { return }
      self.player.stop()
    }
  }

  private nonisolated func stopAndResetEngine() async {
    await withEngineControlQueue { [weak self] in
      guard let self else { return }
      self.player.stop()
      self.engine.stop()
      self.engine.reset()
    }
  }

  @concurrent
  private nonisolated func scrub(
    framePosition: AVAudioFramePosition,
    file: AVAudioFile,
    newInstance: PlaybackInstance,
    play: Bool
  ) async {
    if Task.isCancelled { return }
    await withEngineControlQueue { [weak self] in
      guard let self else { return }
      self.player.stop()
      file.framePosition = framePosition
      self.player
        .scheduleSegment(
          file,
          startingFrame: framePosition,
          frameCount: AVAudioFrameCount(file.length) - AVAudioFrameCount(framePosition),
          at: nil,
          completionCallbackType: .dataPlayedBack,
          completionHandler: { [weak self, newInstance] _ in
            self?.cleanupPlaybackInstance(newInstance)
          }
        )
      if play {
        self.player.play()
      }
    }
  }

  @MainActor
  public func scrub(
    to time: TimeInterval,
    play: Bool,
    updatePlaybackTimer: Bool = true
  ) throws(AIOError) -> Playback? {
    if let initialInstance = state.playbackInstance {
      let playback = getPlayback(for: initialInstance)
      let file = initialInstance.file
      guard playback.duration > time, time >= 0 else {
        throw AIOError.invalidScrubTime(details: time)
      }
      let framePosition = AVAudioFramePosition(time * file.processingFormat.sampleRate)
      let newInstance = PlaybackInstance(
        id: .init(),
        file: file,
        startFrame: framePosition,
        pollingInterval: initialInstance.pollingInterval
      )
      state.playbackInstance = newInstance
      scrubTask = Task(priority: .utility) { [weak self] in
        guard let self else { return }
        await self.scrub(
          framePosition: framePosition,
          file: file,
          newInstance: newInstance,
          play: play
        )
      }

      let newPlayback = Playback(
        id: newInstance.id,
        file: file.url,
        isPlaying: play,
        time: time,
        duration: playback.duration
      )
      defer { setPlayback(newPlayback) }
      if updatePlaybackTimer {
        resetPlaybackTimer(to: newInstance)
      } else {
        playbackTask = nil
      }
      return newPlayback
    } else {
      return nil
    }
  }

  @MainActor
  public func scrubPlay(to time: TimeInterval) throws(AIOError) -> Playback? {
    try scrub(to: time, play: true)
  }

  /// Stops the current playback.
  @MainActor
  public func stopPlayback() async {
    await stopPlayerIfNeeded()
    let finishedFile: AVAudioFile? = state.withLock { state in
      if let foundInstance = state.playbackInstance {
        state.playbackInstance = nil
        return foundInstance.file
      } else {
        return nil
      }
    }
    finishedFile?.close()
    playbackTask = nil
    scrubTask = nil
    placeState(\.playbackInstance, nil)
    playback = nil
    deactivateAudioSessionIfNeeded(reason: "playback stopped")
  }

  /// Pauses the current playback without stopping it.
  ///
  /// The playback can be resumed with ``resumePlayback()``.
  /// Unlike ``stopPlayback()``, this keeps the playback state intact.
  @MainActor
  public func pausePlayback() {
    guard isPlayback else { return }
    engineControlQueue.async { [weak self] in
      self?.player.pause()
    }
    scrubTask = nil
    // Update the playback state to reflect paused status
    if let instance = state.playbackInstance {
      setPlayback(getPlayback(for: instance))
    }
  }

  /// Resumes a paused playback.
  ///
  /// Has no effect if playback is not paused or if there is no active playback.
  @MainActor
  public func resumePlayback() {
    guard isPlayback, !player.isPlaying else { return }
    engineControlQueue.async { [weak self] in
      self?.player.play()
    }
    // Update the playback state to reflect playing status
    if let instance = state.playbackInstance {
      setPlayback(getPlayback(for: instance))
    }
  }

  nonisolated private func cleanupPlaybackInstance(_ instance: PlaybackInstance) {
    let finishedFile: AVAudioFile? = state.withLock { state in
      if let foundInstance = state.playbackInstance, foundInstance.id == instance.id {
        state.playbackInstance = nil
        return foundInstance.file
      } else {
        return nil
      }
    }
    if let finishedFile {
      Task { @MainActor [weak self, state] in
        if state.playbackInstance == nil {
          self?.setPlayback(nil)
          self?.deactivateAudioSessionIfNeeded(reason: "playback finished")
        }
      }
      finishedFile.close()
    }
  }

  public func switchInput(to port: AVAudioSessionPortDescription) throws(AIOError) {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setPreferredInput(port)
    } catch {
      throw .audioSessionFailed(operation: .setPreferredInput, error: ErrorContext(error))
    }
  }

  public func switchOutput(to port: AVAudioSessionPortDescription) throws(AIOError) {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.overrideOutputAudioPort(port.portType == .builtInSpeaker ? .speaker : .none)
    } catch {
      throw .audioSessionFailed(operation: .overrideOutputAudioPort, error: ErrorContext(error))
    }
  }

  @MainActor
  private func configureAudioSession(for configuration: RecordingConfiguration) throws(AIOError) {
    let session = AVAudioSession.sharedInstance()

    try applyAudioSessionConfiguration(session)

    // Set preferred sample rate
    do {
      try session.setPreferredSampleRate(configuration.inputConfiguration.sampleRate.platform)
    } catch {
      throw .audioSessionFailed(operation: .setPreferredSampleRate, error: ErrorContext(error))
    }

    // Set preferred buffer duration for optimal performance
    let preferredDuration = calculatePreferredBufferDuration(
      sampleRate: configuration.inputConfiguration.sampleRate.platform
    )
    do {
      try session.setPreferredIOBufferDuration(preferredDuration)
    } catch {
      throw .audioSessionFailed(
        operation: .setPreferredIOBufferDuration, error: ErrorContext(error))
    }

    // Set preferred input channels if possible
    let desiredChannels = configuration.inputConfiguration.channels.platform
    let channelCount =
      desiredChannels > session.maximumInputNumberOfChannels
      ? AVAudioChannelCount(session.maximumInputNumberOfChannels) : desiredChannels
    do {
      try session.setPreferredInputNumberOfChannels(Int(channelCount))
    } catch {
      throw .audioSessionFailed(
        operation: .setPreferredInputNumberOfChannels, error: ErrorContext(error))
    }

    do {
      try session.setActive(true)
    } catch {
      throw .audioSessionFailed(operation: .setActive, error: ErrorContext(error))
    }

    // Verify actual settings
    log.info(
      "Audio session configured - Sample rate: \(session.sampleRate, privacy: .public), Buffer duration: \(session.ioBufferDuration, privacy: .public), Input channels: \(session.inputNumberOfChannels, privacy: .public)"
    )
  }

  @MainActor
  private func configureAudioSessionForPlayback() throws(AIOError) {
    let session = AVAudioSession.sharedInstance()
    try applyAudioSessionConfiguration(session)
    do {
      try session.setActive(true)
    } catch {
      throw .audioSessionFailed(operation: .setActive, error: ErrorContext(error))
    }
  }

  @MainActor
  private func applyAudioSessionConfiguration(_ session: AVAudioSession) throws(AIOError) {
    let configuration = sessionConfiguration

    if session.category != configuration.category
      || session.mode != configuration.mode
      || session.categoryOptions != configuration.options
    {
      do {
        try session.setCategory(
          configuration.category,
          mode: configuration.mode,
          options: configuration.options
        )
      } catch {
        throw .audioSessionFailed(operation: .setCategory, error: ErrorContext(error))
      }
    }

    if session.allowHapticsAndSystemSoundsDuringRecording
      != configuration.allowsHapticsAndSystemSoundsDuringRecording
    {
      do {
        try session.setAllowHapticsAndSystemSoundsDuringRecording(
          configuration.allowsHapticsAndSystemSoundsDuringRecording
        )
      } catch {
        throw .audioSessionFailed(
          operation: .setAllowHapticsAndSystemSoundsDuringRecording,
          error: ErrorContext(error)
        )
      }
    }

    if session.prefersNoInterruptionsFromSystemAlerts
      != configuration.prefersNoInterruptionsFromSystemAlerts
    {
      do {
        try session.setPrefersNoInterruptionsFromSystemAlerts(
          configuration.prefersNoInterruptionsFromSystemAlerts
        )
      } catch {
        throw .audioSessionFailed(
          operation: .setPrefersNoInterruptionsFromSystemAlerts,
          error: ErrorContext(error)
        )
      }
    }

    if session.prefersInterruptionOnRouteDisconnect
      != configuration.prefersInterruptionOnRouteDisconnect
    {
      do {
        try session.setPrefersInterruptionOnRouteDisconnect(
          configuration.prefersInterruptionOnRouteDisconnect
        )
      } catch {
        throw .audioSessionFailed(
          operation: .setPrefersInterruptionOnRouteDisconnect,
          error: ErrorContext(error)
        )
      }
    }
  }

  @MainActor
  private func deactivateAudioSessionIfNeeded(reason: String) {
    guard deactivateAudioSessionOnStop else { return }
    guard !isRecording, !isPlayback, !wantsRecording else { return }

    let session = AVAudioSession.sharedInstance()
    do {
      try session.setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      let wrapped = AIOError.audioSessionFailed(
        operation: .setActive,
        error: ErrorContext(error)
      )
      log.error(
        "Failed to deactivate audio session (\(reason, privacy: .public)): \(wrapped, privacy: .public)"
      )
      errorSubject.send(wrapped)
    }
  }

  private func calculatePreferredBufferDuration(sampleRate: Double) -> TimeInterval {
    let targetDuration = 0.01  // 10ms
    let baseSamples = targetDuration * sampleRate
    let adjustedSamples = max(baseSamples, 512)
    return adjustedSamples / sampleRate
  }

  // MARK: - Route Change & Interruption Handling

  /// Handles an audio route change.
  ///
  /// This method is called when the audio route changes (e.g., headphones are disconnected).
  /// It attempts to continue recording with the new route if possible.
  ///
  /// - Parameter event: The route change details.
  @MainActor
  public func handleRouteChange(event: AudioRouteChangeEvent) async {
    guard isRecording else {
      await handlePlaybackRouteChange(event: event)
      return
    }

    // Prevent re-entrant calls
    guard !state.isHandlingRouteChange else {
      log.info("Already handling route change, ignoring duplicate")
      return
    }

    state.isHandlingRouteChange = true
    defer { state.isHandlingRouteChange = false }

    log.info("Handling route change: \(String(describing: event.reason), privacy: .public)")

    let session = AVAudioSession.sharedInstance()
    let newInputFormat = runOnEngineControlQueue { engine.inputNode.outputFormat(forBus: 0) }

    guard let currentConfig = state.recordingConfiguration,
      let processingFormat = currentConfig.processingFormat,
      let initialFormat = state.initialInputFormat
    else {
      log.error("Missing configuration during route change")
      return
    }
    let previousFormat = state.lastInputFormat ?? initialFormat

    // Check if we can continue recording
    let canContinue = canContinueRecording(
      from: previousFormat,
      to: newInputFormat,
      processingFormat: processingFormat,
      session: session
    )

    if canContinue {
      // Attempt to continue recording with the new route
      do {
        try reconfigureTapForNewRoute(
          newInputFormat: newInputFormat,
          processingFormat: processingFormat
        )

        // Notify about quality change if channels or sample rate differ
        let qualityChange = createQualityChange(
          from: previousFormat,
          to: newInputFormat,
          reason: describeRouteChangeReason(event.reason)
        )

        let interruption = RecordingInterruption.routeChangeContinuing(
          event: event,
          qualityChange: qualityChange
        )
        await onRecordingInterruption?(interruption)
        placeState(\.lastInputFormat, newInputFormat)

        log.info("Successfully continued recording after route change")
      } catch {
        log.error("Failed to reconfigure tap after route change: \(error, privacy: .public)")
        Task { @MainActor in
          await handleUnrecoverableInterruption(reason: "Route change reconfiguration failed")
        }
      }
    } else {
      // Cannot continue - stop gracefully
      Task { @MainActor in
        await handleUnrecoverableInterruption(reason: "No suitable audio route available")
      }
    }
  }

  @MainActor
  private func handlePlaybackRouteChange(event: AudioRouteChangeEvent) async {
    guard isPlayback else { return }

    let resume = capturePlaybackResumeState()
    guard let resume else { return }

    let (engineIsRunning, playerIsPlaying) = await withEngineControlQueue { [weak self] in
      guard let self else { return (false, false) }
      return (self.engine.isRunning, self.player.isPlaying)
    }

    if resume.wasPlaying {
      if engineIsRunning && playerIsPlaying { return }
    } else {
      if engineIsRunning { return }
    }

    log.info(
      "Playback route change recovery triggered: \(String(describing: event.reason), privacy: .public)"
    )
    await stopPlayback()
    await restartPlayback(from: resume)
  }

  /// Handles an audio session interruption.
  ///
  /// This method is called when the audio session is interrupted (e.g., by a phone call).
  ///
  /// - Parameters:
  ///   - type: The type of interruption.
  ///   - options: The interruption options.
  @MainActor
  public func handleInterruption(
    type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions?
  ) async {
    switch type {
    case .began:
      guard isRecording else { return }
      log.info("Audio interruption began, stopping recording")
      Task { @MainActor in
        await handleUnrecoverableInterruption(reason: "Audio session interrupted")
      }
    case .ended:
      // For now, we don't automatically resume recording after interruptions
      // This could be enhanced in the future based on options.contains(.shouldResume)
      log.info("Audio interruption ended")
    @unknown default:
      break
    }
  }

  @MainActor
  public func handleMediaServicesLost() async {
    log.warning("Media services lost; tearing down engine state")
    let shouldRestartRecording = isRecording || wantsRecording
    let configuration = state.recordingConfiguration ?? lastRecordingConfiguration

    pendingPlaybackResume = capturePlaybackResumeState()
    if pendingPlaybackResume != nil {
      await stopPlayback()
    }

    if shouldRestartRecording {
      pendingRecordingRestart = configuration
      await handleUnrecoverableInterruption(reason: "Media services lost")
    } else {
      pendingRecordingRestart = nil
    }

    await resetEngineForMediaServices()
  }

  @MainActor
  public func handleMediaServicesReset() async {
    log.warning("Media services reset; rebuilding engine state")
    await resetEngineForMediaServices()

    if let configuration = pendingRecordingRestart {
      pendingRecordingRestart = nil
      pendingPlaybackResume = nil
      setDesiredRecordingState(true, configuration: configuration)
      return
    }

    if let resume = pendingPlaybackResume {
      pendingPlaybackResume = nil
      await restartPlayback(from: resume)
    }
  }

  @MainActor
  private func capturePlaybackResumeState() -> PlaybackResume? {
    guard let instance = state.playbackInstance else { return nil }
    let playback = getPlayback(for: instance)
    let time =
      playback.time
      ?? (Double(instance.startFrame) / instance.file.processingFormat.sampleRate)

    return PlaybackResume(
      fileURL: instance.file.url,
      time: time,
      duration: playback.duration,
      wasPlaying: playback.isPlaying,
      pollingInterval: instance.pollingInterval
    )
  }

  @MainActor
  private func restartPlayback(from resume: PlaybackResume) async {
    let duration = resume.duration
    let clampedTime = min(max(0, resume.time), max(0, duration - 0.001))
    guard duration > clampedTime else { return }

    do {
      _ = try await playSegment(
        url: resume.fileURL,
        startTime: clampedTime,
        endTime: duration,
        onComplete: nil,
        playbackPollingInterval: resume.pollingInterval
      )
      if resume.wasPlaying == false {
        pausePlayback()
      }
    } catch {
      log.error("Failed to resume playback after media services reset: \(error, privacy: .public)")
    }
  }

  @MainActor
  private func resetEngineForMediaServices() async {
    await withEngineControlQueue { [weak self] in
      guard let self else { return }
      self.player.stop()
      self.engine.stop()
      self.engine.reset()
      if self.engine.attachedNodes.contains(self.player) == false {
        self.engine.attach(self.player)
      }
    }
  }

  /// Check if recording can continue with the new audio route
  private func canContinueRecording(
    from oldFormat: AVAudioFormat,
    to newFormat: AVAudioFormat,
    processingFormat: AVAudioFormat,
    session: AVAudioSession
  ) -> Bool {
    // Check if there's any input available
    guard session.isInputAvailable else {
      log.info("No input available")
      return false
    }

    // Check if we have at least one input channel
    guard newFormat.channelCount > 0 else {
      log.info("New format has no channels")
      return false
    }

    // Check if processing format has valid channels
    guard processingFormat.channelCount > 0 else {
      log.info("Processing format has no channels")
      return false
    }

    // Validate sample rates are reasonable (between 8kHz and 192kHz)
    // AVAudioConverter can handle conversions between standard audio sample rates
    let minSampleRate: Double = 8000.0
    let maxSampleRate: Double = 192000.0
    guard newFormat.sampleRate >= minSampleRate && newFormat.sampleRate <= maxSampleRate else {
      log.info(
        "New format sample rate out of valid range: \(newFormat.sampleRate, privacy: .public)")
      return false
    }

    // We can continue recording with format conversion as long as:
    // 1. Audio input is available
    // 2. Both new and processing formats have valid channels
    // 3. Sample rate is within reasonable bounds for AVAudioConverter
    // The processAudio method will handle format conversion via AVAudioConverter

    log.info(
      """
      Continuing recording with format conversion:
      - Old format: \(oldFormat.channelCount, privacy: .public) channels @ \(oldFormat.sampleRate, privacy: .public) Hz
      - New format: \(newFormat.channelCount, privacy: .public) channels @ \(newFormat.sampleRate, privacy: .public) Hz
      - Processing format: \(processingFormat.channelCount, privacy: .public) channels @ \(processingFormat.sampleRate, privacy: .public) Hz
      """)

    return true
  }

  /// Reconfigure the audio tap for a new route
  private func reconfigureTapForNewRoute(
    newInputFormat: AVAudioFormat,
    processingFormat: AVAudioFormat
  ) throws(AIOError) {
    // Remove old tap and stop engine before reconfiguring.
    let currentInputFormat = runOnEngineControlQueue { [weak self] in
      guard let self else { return newInputFormat }
      self.engine.inputNode.removeTap(onBus: self.state.installedTapBus ?? 0)
      self.engine.stop()
      return self.engine.inputNode.outputFormat(forBus: 0)
    }
    state.installedTapBus = nil

    // Validate the format before attempting to install tap.
    // installTap throws an uncatchable NSException if the format is invalid.
    guard currentInputFormat.channelCount > 0 else {
      let session = AVAudioSession.sharedInstance()
      let hardwareFormat = runOnEngineControlQueue { engine.inputNode.inputFormat(forBus: 0) }
      let recordPermission = AVAudioApplication.shared.recordPermission
      log.warning(
        """
        Input node has no channels after route change; cannot reconfigure tap.
        recordPermission: \(String(describing: recordPermission), privacy: .public)
        isInputAvailable: \(session.isInputAvailable, privacy: .public)
        outputFormat(forBus: 0): \(currentInputFormat, privacy: .public)
        inputFormat(forBus: 0): \(hardwareFormat, privacy: .public)
        """
      )
      throw AIOError.invalidRecordingConfiguration(
        details: "Input node has no channels after route change (channelCount: 0)")
    }

    guard currentInputFormat.sampleRate > 0 else {
      let session = AVAudioSession.sharedInstance()
      let hardwareFormat = runOnEngineControlQueue { engine.inputNode.inputFormat(forBus: 0) }
      let recordPermission = AVAudioApplication.shared.recordPermission
      log.warning(
        """
        Input node has invalid sample rate after route change; cannot reconfigure tap.
        recordPermission: \(String(describing: recordPermission), privacy: .public)
        isInputAvailable: \(session.isInputAvailable, privacy: .public)
        outputFormat(forBus: 0): \(currentInputFormat, privacy: .public)
        inputFormat(forBus: 0): \(hardwareFormat, privacy: .public)
        """
      )
      throw AIOError.invalidRecordingConfiguration(
        details: "Input node has invalid sample rate after route change (sampleRate: 0)")
    }

    // Get tap configuration using the current format (not the pre-stop format)
    guard let currentConfig = state.recordingConfiguration,
      let tapConfiguration = currentConfig.tapConfiguration(bus: 0, input: currentInputFormat)
    else {
      throw AIOError.invalidRecordingConfiguration(details: "Cannot create tap configuration")
    }
    guard tapConfiguration.bufferSize > 0 else {
      throw AIOError.invalidRecordingConfiguration(details: "Tap bufferSize is 0")
    }

    // Final validation of the format we'll pass to installTap
    let tapFormat = tapConfiguration.inputAVAudioFormat
    guard tapFormat.channelCount > 0, tapFormat.sampleRate > 0 else {
      throw AIOError.invalidRecordingConfiguration(
        details:
          "Tap format is invalid (channels: \(tapFormat.channelCount), sampleRate: \(tapFormat.sampleRate))"
      )
    }

    log.info(
      """
      Installing tap with validated format:
      - Current input format: \(currentInputFormat.channelCount, privacy: .public) ch @ \(currentInputFormat.sampleRate, privacy: .public) Hz
      - Tap format: \(tapFormat.channelCount, privacy: .public) ch @ \(tapFormat.sampleRate, privacy: .public) Hz
      """)

    // Install new tap with updated format
    let startResult = runOnEngineControlQueueResult { [weak self] in
      guard let self else { return }
      self.engine.inputNode.installTap(
        onBus: tapConfiguration.bus,
        bufferSize: tapConfiguration.bufferSize,
        format: tapFormat
      ) {
        @Sendable [bufferReceivers]
        buffer,
        time in
        self.processAudio(
          buffer: buffer,
          time: time,
          to: processingFormat,
          bufferReceivers: bufferReceivers
        )
      }
      try self.engine.start()
    }
    if case .failure(let error) = startResult {
      throw .engineStartFailed(error: ErrorContext(error))
    }

    state.installedTapBus = tapConfiguration.bus

    log.info("Reconfigured tap for new route: \(currentInputFormat, privacy: .public)")
  }

  /// Handle interruptions that cannot be recovered
  @MainActor
  private func handleUnrecoverableInterruption(reason: String) async {
    guard isRecording || wantsRecording else { return }

    log.info("Handling unrecoverable interruption: \(reason, privacy: .public)")

    // Cancel any ongoing reconciliation
    reconciliationTask = nil

    // Notify before stopping
    let interruption = RecordingInterruption.stoppedByInterruption(reason: reason)
    await onRecordingInterruption?(interruption)

    // Stop recording gracefully (also sets wantsRecording = false)
    await gracefulStop()

    // Notify that recording failed (for crash detection/cleanup)
    onRecordingFailed?()
  }

  /// Create quality change event if formats differ
  private func createQualityChange(
    from oldFormat: AVAudioFormat,
    to newFormat: AVAudioFormat,
    reason: String
  ) -> AudioQualityChange? {
    let channelsChanged = oldFormat.channelCount != newFormat.channelCount
    let sampleRateChanged = abs(oldFormat.sampleRate - newFormat.sampleRate) > 1

    if channelsChanged || sampleRateChanged {
      return AudioQualityChange(
        reason: reason,
        previousChannels: oldFormat.channelCount,
        currentChannels: newFormat.channelCount,
        previousSampleRate: oldFormat.sampleRate,
        currentSampleRate: newFormat.sampleRate
      )
    }

    return nil
  }

  /// Convert route change reason to human-readable string
  private func describeRouteChangeReason(_ reason: AVAudioSession.RouteChangeReason) -> String {
    switch reason {
    case .oldDeviceUnavailable:
      return "Device disconnected"
    case .newDeviceAvailable:
      return "New device connected"
    case .categoryChange:
      return "Audio category changed"
    case .override:
      return "Overridden"
    case .routeConfigurationChange:
      return "Route configuration changed"
    case .wakeFromSleep:
      return "Wake from sleep"
    case .noSuitableRouteForCategory:
      return "No suitable route"
    case .unknown:
      return "Unknown reason"
    @unknown default:
      return "Unknown reason"
    }
  }
}

extension AIOEngine: BufferEmitter {

  public typealias T = Float

  /// Attaches a buffer receiver to the engine.
  ///
  /// The receiver will receive real-time audio data while recording.
  ///
  /// - Parameter receiver: The buffer receiver to attach.
  public nonisolated func attachBufferReceiver(_ receiver: consuming some BufferReceiver<Float>)
    async
  {
    await MainActor.run {
      self.bufferReceivers({ $0.append(receiver) })
    }
  }

  /// Detaches all buffer receivers from the engine.
  public nonisolated func detachBufferReceivers() async {
    await MainActor.run {
      self.bufferReceivers({ b in
        defer { b = [] }
        return b
      }).forEach {
        $0.endBufferTask()
      }
    }
  }

  @MainActor
  private func resolveOutputURL(
    for configuration: RecordingConfiguration,
    allowExplicitFile: Bool
  ) throws(AIOError) -> (url: URL, protection: OutputFileProtection?) {
    let filename = Self.generateRecordingFilename(extension: configuration.fileExtension)
#if os(iOS)
    switch configuration.outputDestination {
    case .temporary:
      let resolved: (url: URL, protection: OutputFileProtection?) = (
        FileManager.default.temporaryDirectory.appendingPathComponent(filename, isDirectory: false),
        nil
      )
      logOutputDestination(configuration.outputDestination, url: resolved.0)
      return resolved
    case .directory(let directory, let protection):
      do {
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: true
        )
      } catch {
        throw AIOError.audioFileFailed(
          operation: .openForWriting, url: directory, error: ErrorContext(error)
        )
      }
      applyFileProtectionIfNeeded(protection, to: directory)
      let resolved = (
        directory.appendingPathComponent(filename, isDirectory: false),
        protection
      )
      logOutputDestination(configuration.outputDestination, url: resolved.0)
      return resolved
    case .fileURL(let fileURL, let protection):
      guard allowExplicitFile else {
        throw AIOError.invalidRecordingConfiguration(
          details: "Output destination does not support rotation"
        )
      }
      let parent = fileURL.deletingLastPathComponent()
      do {
        try FileManager.default.createDirectory(
          at: parent,
          withIntermediateDirectories: true
        )
      } catch {
        throw AIOError.audioFileFailed(
          operation: .openForWriting, url: parent, error: ErrorContext(error)
        )
      }
      applyFileProtectionIfNeeded(protection, to: parent)
      let resolved = (fileURL, protection)
      logOutputDestination(configuration.outputDestination, url: resolved.0)
      return resolved
    }
#else
    switch configuration.outputDestination {
    case .temporary:
      let resolved: (url: URL, protection: OutputFileProtection?) = (
        FileManager.default.temporaryDirectory.appendingPathComponent(filename, isDirectory: false),
        nil
      )
      logOutputDestination(configuration.outputDestination, url: resolved.0)
      return resolved
    case .directory(let directory):
      do {
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: true
        )
      } catch {
        throw AIOError.audioFileFailed(
          operation: .openForWriting, url: directory, error: ErrorContext(error)
        )
      }
      let resolved: (url: URL, protection: OutputFileProtection?) = (
        directory.appendingPathComponent(filename, isDirectory: false),
        nil
      )
      logOutputDestination(configuration.outputDestination, url: resolved.0)
      return resolved
    case .fileURL(let fileURL):
      guard allowExplicitFile else {
        throw AIOError.invalidRecordingConfiguration(
          details: "Output destination does not support rotation"
        )
      }
      let parent = fileURL.deletingLastPathComponent()
      do {
        try FileManager.default.createDirectory(
          at: parent,
          withIntermediateDirectories: true
        )
      } catch {
        throw AIOError.audioFileFailed(
          operation: .openForWriting, url: parent, error: ErrorContext(error)
        )
      }
      let resolved: (url: URL, protection: OutputFileProtection?) = (fileURL, nil)
      logOutputDestination(configuration.outputDestination, url: resolved.0)
      return resolved
    }
#endif
  }

  private nonisolated func audioFileTypeID(for format: FileFormat) -> AudioFileTypeID {
    switch format {
    case .aac: return kAudioFileM4AType
    case .adts: return kAudioFileAAC_ADTSType
    case .wav: return kAudioFileWAVEType
    case .aiff: return kAudioFileAIFFType
    case .caf: return kAudioFileCAFType
    case .flac: return kAudioFileFLACType
    }
  }

  @MainActor
  private func makeRecordingWriter(
    url: URL,
    configuration: RecordingConfiguration
  ) throws(AIOError) -> RecordingFileWriter {
    guard let fileSettings = configuration.fileSettings else {
      throw AIOError.invalidRecordingConfiguration(details: "(file format settings)")
    }
    guard let processingFormat = configuration.processingFormat else {
      throw AIOError.invalidRecordingConfiguration(details: "processing format")
    }
    switch writerBackend {
    case .avAudioFile:
      do {
        let file = try AVAudioFile(forWriting: url, settings: fileSettings)
        return AVAudioFileWriter(file: file)
      } catch {
        throw AIOError.audioFileFailed(
          operation: .openForWriting, url: url, error: ErrorContext(error)
        )
      }
    case .extAudioFile:
      guard let outputFormat = AVAudioFormat(settings: fileSettings) else {
        throw AIOError.invalidRecordingConfiguration(details: "file format settings")
      }
      do {
        return try ExtAudioFileWriter(
          url: url,
          fileType: audioFileTypeID(for: configuration.outputConfiguration.fileFormat),
          outputFormat: outputFormat,
          clientFormat: processingFormat
        )
      } catch {
        throw AIOError.audioFileFailed(
          operation: .openForWriting, url: url, error: ErrorContext(error)
        )
      }
    }
  }

  @MainActor
  private func applyFileProtectionIfNeeded(
    _ protection: OutputFileProtection?,
    to url: URL
  ) {
#if os(iOS)
    guard let protection else { return }
    do {
      try FileManager.default.setAttributes(
        [.protectionKey: protection],
        ofItemAtPath: url.path
      )
    } catch {
      log.error(
        "🔒 Failed to apply file protection to \(url.path, privacy: .public): \(error, privacy: .public)"
      )
    }
#else
    _ = protection
    _ = url
#endif
  }

  private nonisolated func fileSizeDescription(for url: URL) -> String {
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
      return "\(size)"
    }
    return "unknown"
  }

  private nonisolated func fileSizeValue(for url: URL) -> Int? {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
  }

  private nonisolated func logOutputDestination(
    _ destination: RecordingConfiguration.OutputDestination,
    url: URL
  ) {
    log.info(
      "🎯 Recording output: destination=\(destination, privacy: .public) url=\(url.lastPathComponent, privacy: .public)"
    )
  }

  // MARK: - Filename Generation

  /// Generates a semantic filename for recordings.
  private static func generateRecordingFilename(extension ext: String) -> String {
    RecordingFilename(fileExtension: ext).filename
  }
}
#endif
