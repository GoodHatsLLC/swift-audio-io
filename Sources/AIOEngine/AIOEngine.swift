#if canImport(AVFoundation)
  @preconcurrency import AVFoundation
  import Tools
  import AsyncAlgorithms
  import Dispatch
  import Foundation
  import SystemLog

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
  /// - ``handleRouteChange(reason:)``
  /// - ``handleInterruption(type:options:)``
  ///
  private let log = SystemLog.make()

  @Observable
  public final class AIOEngine: Sendable {
    /// Errors that can occur during audio engine operations.
    public enum AIOError: Error, LocalizedError {
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
        }
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
        "\(reason): channels \(previousChannels)→\(currentChannels), sample rate \(previousSampleRate)→\(currentSampleRate)"
      }
    }

    /// An event representing a recording interruption.
    public enum RecordingInterruption: Sendable {
      /// The audio route changed, but recording is continuing.
      case routeChangeContinuing(reason: String, qualityChange: AudioQualityChange?)
      /// The recording was stopped gracefully.
      case stoppedGracefully(reason: String)
      /// The recording was stopped by an interruption (e.g., a phone call).
      case stoppedByInterruption(reason: String)

      public var description: String {
        switch self {
        case .routeChangeContinuing(let reason, let qualityChange):
          if let change = qualityChange {
            return "Route changed (\(reason)), continuing with: \(change.description)"
          } else {
            return "Route changed (\(reason)), continuing with same quality"
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

    private nonisolated let engine = AVAudioEngine()
    private nonisolated let player = AVAudioPlayerNode()

    struct InternalState {
      var file: AVAudioFile?
      var recordingURL: URL?
      var recordingConfiguration: RecordingConfiguration?
      var playbackInstance: PlaybackInstance?
      var installedTapBus: Int?
      var audioBuffers: [RingBuffer<Float>]?
      var isHandlingRouteChange: Bool = false
      var initialInputFormat: AVAudioFormat?
    }
    private let state: Synchronized<InternalState> = .init(.init())

    nonisolated func placeState<T>(_ path: WritableKeyPath<InternalState, T>, _ field: T) {
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
    private func setPlayback(_ new: Playback?) {
      guard let playbackInstance = state.playbackInstance else {
        playback = nil
        return
      }
      if new?.id == playbackInstance.id {
        playback = new
      } else if new == nil {
        playback = nil
      }
    }

    private func getPlayback() -> Playback? {
      guard let playbackInstance = state.playbackInstance else { return nil }
      return getPlayback(for: playbackInstance)
    }

    private func getPlayback(for instance: PlaybackInstance) -> Playback {
      guard let nodeTime = player.lastRenderTime,
        let playerTime = player.playerTime(forNodeTime: nodeTime)
      else {
        return Playback(
          id: instance.id,
          file: instance.file.url,
          isPlaying: player.isPlaying,
          time: 0,
          duration: Double(instance.file.length) / instance.file.processingFormat.sampleRate
        )
      }

      let sampleRate = playerTime.sampleRate
      let timeInPlayer = Double(playerTime.sampleTime) / sampleRate
      let startOffset =
        Double(instance.file.framePosition) / instance.file.processingFormat.sampleRate
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

    @MainActor private var writerTask: Task<Void, Error>? {
      willSet {
        if writerTask != newValue {
          writerTask?.cancel()
        }
      }
    }

    @MainActor private var playbackTask: Task<Void, Error>? {
      willSet {
        if playbackTask != newValue {
          playbackTask?.cancel()
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
      engine.attach(player)
    }

    /// Creates a new instance of the audio engine with custom reconciliation configuration.
    ///
    /// - Parameter reconciliationConfiguration: Configuration for state reconciliation.
    @MainActor public init(reconciliationConfiguration: ReconciliationConfiguration) {
      self.reconciliationConfiguration = reconciliationConfiguration
      engine.attach(player)
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
        } catch let error as AIOError where error.isTransient {
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
    public nonisolated func startRecording(configuration: RecordingConfiguration) async throws {
      try await Task { @MainActor in
        // Stop any active playback before recording
        if player.isPlaying {
          player.stop()
          placeState(\.playbackInstance, nil)
          playback = nil
        }
        try warm(configuration: configuration)

        let (buffers, writefile) = state { ($0.audioBuffers, $0.file) }
        guard let buffers = buffers,
          let processingFormat = configuration.processingFormat,
          let writeFile = writefile,
          let url = writefile?.url
        else {
          throw AIOError.invalidRecordingConfiguration(
            details: "state after warm(configuration:) was invalid")
        }
        try engine.start()
        let fileFormat = configuration.outputConfiguration.fileFormat.rawValue
        onRecordingStarted?(url, fileFormat)
        startFileWriteLoop(flushing: buffers, of: processingFormat, to: writeFile)
        self.isRecording = true
      }.value
    }

    @MainActor private func startFileWriteLoop(
      flushing buffers: [RingBuffer<Float>],
      of processingFormat: AVAudioFormat,
      to file: AVAudioFile
    ) {
      writerTask = Task.detached(priority: .userInitiated) {
        try await AIOEngine.writerLoop(
          file: file,
          format: processingFormat,
          audioBuffers: buffers
        )
      }

    }

    /// Warms up the audio engine with the specified configuration.
    ///
    /// This method prepares the audio engine for recording by configuring the audio session,
    /// setting up the necessary buffers, and installing an audio tap.
    ///
    /// - Parameter configuration: The configuration to use for recording.
    /// - Throws: An `AIOError` if the configuration is invalid or if the engine fails to warm up.
    @MainActor
    public func warm(configuration: RecordingConfiguration) throws {
      guard !isRecording && !isPlaying else {
        return
      }
      log.info("warming with config: \(configuration, privacy: .public)")
      let initialInput = engine.inputNode.inputFormat(forBus: 0)
      log.info("input format: \(initialInput, privacy: .public)")
      if let recordingConfiguration = state.recordingConfiguration {
        if configuration == recordingConfiguration {
          log.info("engine already warmed")
          return
        } else {
          log.info("engine requires hard stop")
          // TODO: reconfigure active recording instead
          hardStop()
        }
      }
      log.info("engine requires warming")
      do {

        guard let fileSettings = configuration.fileFormat?.settings else {
          throw AIOError.invalidRecordingConfiguration(details: "(file format settings)")
        }
        // Configure audio session
        try configureAudioSession(for: configuration)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
          Self.generateRecordingFilename(extension: configuration.fileExtension),
          conformingTo: configuration.outputConfiguration.fileFormat.utType)

        let file = try AVAudioFile(forWriting: url, settings: fileSettings)

        let inputFormat = engine.inputNode.inputFormat(forBus: 0)

        // Validate input format before attempting to install tap
        // installTap throws an uncatchable NSException if the format is invalid
        guard inputFormat.channelCount > 0 else {
          log.warning(
            "Input node has no channels: channelCount=\(inputFormat.channelCount, privacy: .public)"
          )
          throw AIOError.audioSessionNotReady(
            details: "Input node has no channels (channelCount: 0)"
          )
        }
        guard inputFormat.sampleRate > 0 else {
          log.warning(
            "Input node has invalid sample rate: sampleRate=\(inputFormat.sampleRate, privacy: .public)"
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

        let audioBuffers = (0..<channelCount).map { _ in
          RingBuffer<Float>(capacity: sampleRate * channelCount * 2)  // 2 seconds of buffer
        }

        guard let tapConfiguration = configuration.tapConfiguration(bus: 0, input: inputFormat)
        else {
          throw AIOError.invalidRecordingConfiguration(details: "(Tap configuration)")
        }
        // Install tap
        engine.inputNode.installTap(
          onBus: tapConfiguration.bus,
          bufferSize: tapConfiguration.bufferSize,
          format: tapConfiguration.inputAVAudioFormat
        ) {
          @Sendable [bufferReceivers]
          buffer,
          _ in
          self.processAudio(
            buffer: buffer,
            to: processingFormat,
            enqueueingTo: audioBuffers,
            bufferReceivers: bufferReceivers
          )
        }
        engine.prepare()

        state {
          $0.file = file
          $0.recordingURL = url
          $0.audioBuffers = audioBuffers
          $0.installedTapBus = tapConfiguration.bus
          $0.recordingConfiguration = configuration
          $0.initialInputFormat = inputFormat
        }
      } catch {
        log.error(
          "Failed to warm engine: \(error, privacy: .public) (\((((error as? AVError)?.code as? Int) ?? (error as NSError).code as Int), privacy: .public))"
        )
        hardStop()
        onRecordingFailed?()
        throw error
      }
    }

    @MainActor private func hardStop() {
      let tapBus = state.consume(\.installedTapBus)
      if let tapBus {
        engine.inputNode.removeTap(onBus: tapBus)
      }
      if engine.isRunning {
        engine.disconnectNodeOutput(player)
        engine.stop()
      }
      writerTask = nil
      cleanUp()
    }

    @MainActor
    private func gracefulStop() async {
      let tapBus = state.consume(\.installedTapBus)
      if let tapBus = tapBus {
        engine.inputNode.removeTap(onBus: tapBus)
      }
      engine.stop()
      if let writerTask {
        writerTask.cancel()
        do {
          _ = try await withTimeout(of: .seconds(3)) {
            await writerTask.result
          }
        } catch {
          log.error("writer task timed out after 3 seconds")
        }
      }
      cleanUp()
      isRecording = false
      wantsRecording = false
      reconciliationTask = nil
    }

    @MainActor private func cleanUp() {
      let file = state { state in
        defer {
          state.file = nil
          state.recordingURL = nil
          state.recordingConfiguration = nil
          state.audioBuffers = nil
          state.initialInputFormat = nil
          state.isHandlingRouteChange = false
        }
        return state.file
      }
      file?.close()
      cache.withLock { c in
        c.cachedTapConverter = nil
        c.cachedConverterInputFormat = nil
        c.cachedConverterOutputFormat = nil
        c.cachedConvertedBuffer = nil
      }
      writerTask = nil
      playbackTask = nil
    }

    nonisolated private func processAudio(
      buffer: AVAudioPCMBuffer,
      to processingFormat: AVAudioFormat,
      enqueueingTo audioBuffers: [RingBuffer<Float>],
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
              input buffer: \(buffer.format)
              cached input converter: \(cachedConverterInputFormat)
              cached output converter: \(cachedConverterOutputFormat)
              processingFormat: \(processingFormat)
          """)
        guard let newConverter = AVAudioConverter(from: buffer.format, to: processingFormat) else {
          let error = AIOError.formatConversionFailed
          log.error("Failed to create audio converter: \(error)")
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

      // Enqueue to ring buffers
      let channelCount = Int(convertedBuffer.format.channelCount)
      guard channelCount <= audioBuffers.count else {
        log.error("Channel count mismatch: \(channelCount) vs \(audioBuffers.count)")
        return
      }

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
            $0.processBuffer(UnsafeBufferPointer(start: channelData, count: frameLength))
          }
        }
      }
    }

    private static func writerLoop(
      file: AVAudioFile,
      format: AVAudioFormat,
      audioBuffers: [RingBuffer<Float>]
    ) async throws {
      let bufferSize = 1024  // Write in chunks

      while !Task.isCancelled {
        do {
          let framesRead = try flushChunk(
            size: bufferSize,
            from: audioBuffers,
            in: format,
            to: file
          )
          if framesRead == 0 {
            if Task.isCancelled {
              return
            } else {
              // await more audio
              await Task.yield()
            }
          }
        } catch {
          log.error("error flushing chunk: \(error)")
        }
      }
    }

    private static func flushChunk(
      size bufferSize: Int,
      from audioBuffers: [RingBuffer<Float>],
      in audioFormat: AVAudioFormat,
      to file: AVAudioFile
    ) throws -> Int {
      let channelCount = Int(audioFormat.channelCount)
      let framesToRead = minimumAvailableFrames(
        channelCount: channelCount,
        audioBuffers: audioBuffers,
        limit: bufferSize
      )

      guard framesToRead > 0 else {
        return 0
      }

      guard
        let pcmBuffer = AVAudioPCMBuffer(
          pcmFormat: audioFormat,
          frameCapacity: AVAudioFrameCount(bufferSize)
        )
      else {
        return 0
      }

      var actualFrames = framesToRead
      // Dequeue from ring buffers using a consistent frame count per channel
      for i in 0..<channelCount {
        guard let channelData = pcmBuffer.floatChannelData?[i] else {
          actualFrames = 0
          return 0
        }
        let readSize = audioBuffers[i].read(
          into: UnsafeMutableBufferPointer(start: channelData, count: framesToRead))
        actualFrames = min(actualFrames, readSize)
      }

      guard actualFrames > 0 else { return framesToRead }
      pcmBuffer.frameLength = AVAudioFrameCount(actualFrames)

      try file.write(from: pcmBuffer)
      return actualFrames

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
    public func stopRecording() async throws -> URL {
      guard let url = state.recordingURL, isRecording else { throw AIOError.notRecording }
      await gracefulStop()
      onRecordingCompleted?()
      return url
    }

    /// Plays an audio file from the specified URL.
    ///
    /// This method stops any current playback or recording before starting the new playback.
    ///
    /// - Parameter url: The URL of the audio file to play.
    /// - Returns: A `Playback` instance representing the current playback state.
    /// - Throws: An `AIOError.cannotPlayWhileRecording` error if the engine is currently recording.
    @MainActor
    public func play(url: URL) throws -> Playback {
      // Prevent playback while recording
      guard !isRecording else {
        throw AIOError.cannotPlayWhileRecording
      }

      if getPlayback() != nil {
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        state.playbackInstance = nil
        setPlayback(nil)
      } else {
        engine.stop()
        player.stop()
      }

      let file = try AVAudioFile(forReading: url)
      let playbackInstance = PlaybackInstance(id: .init(), file: file)

      // Connect the player node to the output node.
      // Note: player is already attached in init(), we only need to connect it.
      engine.connect(
        player,
        to: engine.outputNode,
        format: file.processingFormat)
      state.playbackInstance = playbackInstance
      let player = player
      player
        .scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) {
          [
            weak self,
            playbackInstance
          ] _ in
          self?.cleanupPlaybackInstance(playbackInstance)
        }
      try engine.start()
      let playback = getPlayback(for: playbackInstance)
      setPlayback(playback)
      player.play()
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
      onComplete: (@MainActor @Sendable () -> Void)? = nil
    ) throws -> Playback {
      guard !isRecording else {
        throw AIOError.cannotPlayWhileRecording
      }

      // Stop any existing playback
      if getPlayback() != nil {
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        state.playbackInstance = nil
        setPlayback(nil)
      } else {
        engine.stop()
        player.stop()
      }

      let file = try AVAudioFile(forReading: url)
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

      let playbackInstance = PlaybackInstance(id: .init(), file: file)

      engine.connect(player, to: engine.outputNode, format: file.processingFormat)
      state.playbackInstance = playbackInstance

      let player = player
      player.scheduleSegment(
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

      try engine.start()

      // Create playback state reflecting the segment (not full file)
      let segmentPlayback = Playback(
        id: playbackInstance.id,
        file: url,
        isPlaying: true,
        time: startTime,
        duration: endTime  // Use endTime as duration for progress calculation
      )
      setPlayback(segmentPlayback)
      player.play()
      resetPlaybackTimer(to: playbackInstance)

      return segmentPlayback
    }

    @MainActor func resetPlaybackTimer(to instance: PlaybackInstance) {
      playbackTask = Task { @MainActor in
        for await _ in AsyncTimerSequence(interval: .seconds(0.5), clock: .suspending) {
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

    @concurrent
    private nonisolated func scrub(
      framePosition: AVAudioFramePosition,
      file: AVAudioFile,
      newInstance: PlaybackInstance
    ) async {
      player.stop()
      file.framePosition = framePosition
      player
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
      player.play()
    }

    @concurrent
    private nonisolated func stopPlayback() async {
      player.stop()
    }

    @MainActor
    public func scrubPlay(to time: TimeInterval) throws -> Playback? {
      if let initialInstance = state.playbackInstance {
        let playback = getPlayback(for: initialInstance)
        let file = initialInstance.file
        guard playback.duration > time, time >= 0 else {
          throw AIOError.notRecording
        }
        let framePosition = AVAudioFramePosition(time * file.processingFormat.sampleRate)
        let newInstance = PlaybackInstance(id: .init(), file: file)
        state.playbackInstance = newInstance
        Task {
          await scrub(framePosition: framePosition, file: file, newInstance: newInstance)
        }

        let newPlayback = Playback(
          id: newInstance.id,
          file: file.url,
          isPlaying: true,
          time: time,
          duration: playback.duration
        )
        defer { setPlayback(newPlayback) }
        resetPlaybackTimer(to: newInstance)
        return newPlayback
      } else {
        return nil
      }
    }

    /// Stops the current playback.
    ///
    /// - Throws: An `AIOError.notPlaying` error if no audio is currently playing.
    @MainActor
    public func stopPlayback() throws {
      if player.isPlaying {
        Task {
          await self.stopPlayback()
        }
      }
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
      placeState(\.playbackInstance, nil)
      playback = nil
    }

    /// Pauses the current playback without stopping it.
    ///
    /// The playback can be resumed with ``resumePlayback()``.
    /// Unlike ``stopPlayback()``, this keeps the playback state intact.
    @MainActor
    public func pausePlayback() {
      guard isPlayback else { return }
      player.pause()
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
      player.play()
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
          }
        }
        finishedFile.close()
      }
    }

    public func switchInput(to port: AVAudioSessionPortDescription) throws {
      let session = AVAudioSession.sharedInstance()
      try session.setPreferredInput(port)
    }

    public func switchOutput(to port: AVAudioSessionPortDescription) throws {
      let session = AVAudioSession.sharedInstance()
      try session.overrideOutputAudioPort(port.portType == .builtInSpeaker ? .speaker : .none)
    }

    private func configureAudioSession(for configuration: RecordingConfiguration) throws {
      let session = AVAudioSession.sharedInstance()

      // Set preferred sample rate
      try session.setPreferredSampleRate(configuration.inputConfiguration.sampleRate.platform)

      // Set preferred buffer duration for optimal performance
      let preferredDuration = calculatePreferredBufferDuration(
        sampleRate: configuration.inputConfiguration.sampleRate.platform
      )
      try session.setPreferredIOBufferDuration(preferredDuration)

      // Set preferred input channels if possible
      let desiredChannels = configuration.inputConfiguration.channels.platform
      let channelCount =
        desiredChannels > session.maximumInputNumberOfChannels
        ? AVAudioChannelCount(session.maximumInputNumberOfChannels) : desiredChannels
      try session.setPreferredInputNumberOfChannels(Int(channelCount))

      try session.setActive(true)

      // Verify actual settings
      log.info(
        "Audio session configured - Sample rate: \(session.sampleRate, privacy: .public), Buffer duration: \(session.ioBufferDuration, privacy: .public), Input channels: \(session.inputNumberOfChannels, privacy: .public)"
      )
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
    /// - Parameter reason: The reason for the route change.
    @MainActor
    public func handleRouteChange(reason: AVAudioSession.RouteChangeReason) async {
      guard isRecording else { return }

      // Prevent re-entrant calls
      guard !state.isHandlingRouteChange else {
        log.info("Already handling route change, ignoring duplicate")
        return
      }

      state.isHandlingRouteChange = true
      defer { state.isHandlingRouteChange = false }

      log.info("Handling route change: \(String(describing: reason), privacy: .public)")

      let session = AVAudioSession.sharedInstance()
      let newInputFormat = engine.inputNode.inputFormat(forBus: 0)

      guard let currentConfig = state.recordingConfiguration,
        let processingFormat = currentConfig.processingFormat,
        let file = state.file,
        let initialFormat = state.initialInputFormat
      else {
        log.error("Missing configuration or file during route change")
        return
      }

      // Check if we can continue recording
      let canContinue = canContinueRecording(
        from: initialFormat,
        to: newInputFormat,
        processingFormat: processingFormat,
        session: session
      )

      if canContinue {
        // Attempt to continue recording with the new route
        do {
          try reconfigureTapForNewRoute(
            newInputFormat: newInputFormat,
            processingFormat: processingFormat,
            file: file
          )

          // Notify about quality change if channels or sample rate differ
          let qualityChange = createQualityChange(
            from: initialFormat,
            to: newInputFormat,
            reason: describeRouteChangeReason(reason)
          )

          let interruption = RecordingInterruption.routeChangeContinuing(
            reason: describeRouteChangeReason(reason),
            qualityChange: qualityChange
          )
          await onRecordingInterruption?(interruption)

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
      processingFormat: AVAudioFormat,
      file: AVAudioFile
    ) throws {
      // Remove old tap
      if let tapBus = state.installedTapBus {
        engine.inputNode.removeTap(onBus: tapBus)
        state.installedTapBus = nil
      }

      // Stop engine briefly
      engine.stop()

      // Re-fetch the input format after stopping - it may have changed
      // This is critical because the engine state can change after stop()
      let currentInputFormat = engine.inputNode.inputFormat(forBus: 0)

      // Validate the format before attempting to install tap
      // installTap throws an uncatchable NSException if the format is invalid
      guard currentInputFormat.channelCount > 0 else {
        throw AIOError.invalidRecordingConfiguration(
          details: "Input node has no channels after route change (channelCount: 0)")
      }

      guard currentInputFormat.sampleRate > 0 else {
        throw AIOError.invalidRecordingConfiguration(
          details: "Input node has invalid sample rate after route change (sampleRate: 0)")
      }

      // Get tap configuration using the current format (not the pre-stop format)
      guard let currentConfig = state.recordingConfiguration,
        let tapConfiguration = currentConfig.tapConfiguration(bus: 0, input: currentInputFormat)
      else {
        throw AIOError.invalidRecordingConfiguration(details: "Cannot create tap configuration")
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
      let audioBuffers = state.audioBuffers ?? []
      engine.inputNode.installTap(
        onBus: tapConfiguration.bus,
        bufferSize: tapConfiguration.bufferSize,
        format: tapFormat
      ) {
        @Sendable [bufferReceivers]
        buffer,
        _ in
        self.processAudio(
          buffer: buffer,
          to: processingFormat,
          enqueueingTo: audioBuffers,
          bufferReceivers: bufferReceivers
        )
      }

      state.installedTapBus = tapConfiguration.bus

      // Restart engine
      try engine.start()

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
        return "Route overridden"
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
      _ = await Task { @MainActor in
        self.bufferReceivers({ $0.append(receiver) })
      }.result
    }

    /// Detaches all buffer receivers from the engine.
    public nonisolated func detachBufferReceivers() async {
      _ = await Task { @MainActor in
        self.bufferReceivers({ b in
          defer { b = [] }
          return b
        }).forEach {
          $0.endBufferTask()
        }
      }.result
    }

    // MARK: - Filename Generation

    /// Generates a semantic filename for recordings.
    private static func generateRecordingFilename(extension ext: String) -> String {
      RecordingFilename(fileExtension: ext).filename
    }
  }

#endif
