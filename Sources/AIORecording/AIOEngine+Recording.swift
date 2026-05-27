// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOContracts
  import AIOSupport
  import AIOEngineCore
  package import AIORecordingSupport
  import AsyncAlgorithms
  import Atomics
  package import AVFoundation
  import Foundation
  import os
  package import Tools

  private let log = SystemLog.make()

  extension AIOEngine {
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
      configuration: RecordingConfiguration? = nil,
    ) {
      recordingRuntime.setDesiredRecordingState(desiredState, configuration: configuration)
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
      configuration: RecordingConfiguration,
    ) async -> Bool {
      await recordingRuntime.startRecordingWithReconciliation(configuration: configuration)
    }

    /// Stops recording.
    ///
    /// This is a convenience method that sets the desired state to false
    /// and waits for the recording to stop.
    ///
    /// - Returns: The URL of the recorded file, or `nil` if not recording.
    @MainActor
    public func stopRecordingWithReconciliation() async -> URL? {
      await recordingRuntime.stopRecordingWithReconciliation()
    }

    /// Attempts to reconcile the desired recording state with the actual state.
    @MainActor
    func reconcileRecordingState(
      desiredState: Bool,
      configuration: RecordingConfiguration,
    ) async {
      await recordingRuntime.reconcileRecordingState(
        desiredState: desiredState,
        configuration: configuration,
      )
    }

    /// Starts recording audio with the specified configuration.
    ///
    /// This method first stops any active playback and then warms up the engine with the provided configuration.
    /// Once the engine is ready, it starts recording audio to a temporary file.
    ///
    /// - Parameter configuration: The configuration to use for recording.
    /// - Throws: A ``RecordingError`` if the recording configuration is invalid or if the engine fails to start.
    public nonisolated func startRecording(
      configuration: RecordingConfiguration,
    ) async throws(RecordingError) {
      try await recordingRuntime.startRecording(configuration: configuration)
    }

    @MainActor package func startFileWriteLoop(
      flushing buffers: [SPSCRingBuffer<Float>],
      of processingFormat: AVAudioFormat,
      to writer: any RecordingFileWriter,
    ) {
      recordingEngineRuntime.startFileWriteLoop(
        flushing: buffers,
        of: processingFormat,
        to: writer,
      )
    }

    @MainActor package func startReceiverLoop(
      buffers: [SPSCRingBuffer<Float>],
      timing: SPSCRingBuffer<TimingPacket>,
      processingFormat: AVAudioFormat,
    ) {
      recordingEngineRuntime.startReceiverLoop(
        buffers: buffers,
        timing: timing,
        processingFormat: processingFormat,
      )
    }

    @MainActor func stopReceiverLoop() {
      recordingEngineRuntime.stopReceiverLoop()
    }

    @MainActor
    func prepareDrain(for session: WriterSession, targetSampleTime: Int64, logBuffers: Bool) {
      recordingEngineRuntime.prepareDrain(
        for: session,
        targetSampleTime: targetSampleTime,
        logBuffers: logBuffers,
      )
    }

    @MainActor
    func drainWriterSession(_ session: WriterSession, notifyOnFailure: Bool) async {
      await recordingEngineRuntime.drainWriterSession(
        session,
        notifyOnFailure: notifyOnFailure,
      )
    }

    @MainActor
    package
      func enqueueDrain(for session: WriterSession)
    {
      recordingEngineRuntime.enqueueDrain(for: session)
    }

    @MainActor
    func stopAndDrainAllWriterSessions(notifyOnFailure: Bool) async {
      await recordingEngineRuntime.stopAndDrainAllWriterSessions(
        notifyOnFailure: notifyOnFailure,
      )
    }

    @MainActor
    func cancelAllWriterSessions() {
      recordingEngineRuntime.cancelAllWriterSessions()
    }

    @MainActor
    func recordWriteFailure(_ error: ErrorContext, url: URL?) {
      recordingEngineRuntime.recordWriteFailure(error, url: url)
    }

    @MainActor
    func consumeWriteFailure() -> WriteFailure? {
      recordingEngineRuntime.consumeWriteFailure()
    }

    /// Warms up the audio engine with the specified configuration.
    ///
    /// This method prepares the audio engine for recording by configuring the audio session,
    /// setting up the necessary buffers, and installing an audio tap.
    ///
    /// - Parameter configuration: The configuration to use for recording.
    /// - Throws: A ``RecordingError`` if the configuration is invalid or if the engine fails to warm up.
    @MainActor
    public func warm(configuration: RecordingConfiguration) throws(RecordingError) {
      try recordingEngineRuntime.warm(configuration: configuration)
    }

    package func makeAudioBuffers(
      sampleRate: Int,
      channelCount: Int,
    ) -> [SPSCRingBuffer<Float>] {
      recordingEngineRuntime.makeAudioBuffers(
        sampleRate: sampleRate,
        channelCount: channelCount,
      )
    }

    package func validateRecordingChannelCapacity(
      channelCount: Int,
    ) throws(RecordingError) {
      try recordingEngineRuntime.validateRecordingChannelCapacity(channelCount: channelCount)
    }

    package func validateRecordingChannelCapacity(
      for configuration: RecordingConfiguration,
    ) throws(RecordingError) {
      try recordingEngineRuntime.validateRecordingChannelCapacity(for: configuration)
    }

    @MainActor
    func validateEncoderCompatibility(
      for configuration: RecordingConfiguration,
    ) throws(RecordingError) {
      try recordingEngineRuntime.validateEncoderCompatibility(for: configuration)
    }

    @MainActor
    public func updateRecordingTapInterval(_ interval: Duration) {
      recordingRuntime.updateRecordingTapInterval(interval)
    }

    @MainActor
    func reconfigureTapForIntervalChange(
      configuration: RecordingConfiguration,
    ) throws(RecordingError) {
      try recordingEngineRuntime.reconfigureTapForIntervalChange(configuration: configuration)
    }

    /// Thread Domain: MainActor (entry point), engineControl (graph mutations).
    @MainActor func hardStop() {
      recordingEngineRuntime.hardStop()
    }

    /// Thread Domain: MainActor (entry point), engineControl (graph mutations).
    @MainActor
    package func gracefulStop() async {
      await recordingEngineRuntime.gracefulStop()
    }

    @MainActor func cleanUp(closeFile: Bool = true) {
      recordingEngineRuntime.cleanUp(closeFile: closeFile)
    }

    // MARK: - Thread Domain: tapCallback

    ///
    /// Threading model for the audio pipeline:
    /// - Tap callback (processAudio): semi-RT thread managed by AVAudioEngine's
    ///   internal RealtimeMessenger.mServiceQueue. Must avoid blocking locks,
    ///   heap allocations, and ObjC messaging where possible. Uses
    ///   withLockIfAvailable for non-blocking state access with a cached
    ///   snapshot fallback.
    /// - Writer loop: writerQueue (serial, .userInitiated), file I/O only.
    /// - Engine control: engineControlQueue (serial, .default) for all
    ///   AVAudioEngine graph mutations.
    /// - Receiver loop: receiverQueue (serial, .userInitiated), visualization.
    package nonisolated func processAudio(
      buffer: AVAudioPCMBuffer,
      time: AVAudioTime?,
      to processingFormat: AVAudioFormat,
    ) {
      recordingEngineRuntime.processAudio(buffer: buffer, time: time, to: processingFormat)
    }

    nonisolated func formatsCompatible(
      _ lhs: AVAudioFormat,
      _ rhs: AVAudioFormat,
    ) -> Bool {
      recordingEngineRuntime.formatsCompatible(lhs, rhs)
    }

    /// Thread Domain: writerQueue
    static func writerLoopSync(
      writer: any RecordingFileWriter,
      format: AVAudioFormat,
      audioBuffers: [SPSCRingBuffer<Float>],
      writeBuffer: AVAudioPCMBuffer?,
      control: WriterControl,
      metrics: EngineMetrics,
      clock: ContinuousClock = .continuous,
      shouldCancel: @escaping @Sendable () -> Bool,
      errorHandler: @escaping @Sendable (ErrorContext) -> Void,
      tapErrorPoll: (@Sendable () -> TapErrorCode?)?,
      onTapError: (@Sendable (TapErrorCode) -> Void)?,
    ) {
      RecordingEngineRuntime.writerLoopSync(
        writer: writer,
        format: format,
        audioBuffers: audioBuffers,
        writeBuffer: writeBuffer,
        control: control,
        metrics: metrics,
        clock: clock,
        shouldCancel: shouldCancel,
        errorHandler: errorHandler,
        tapErrorPoll: tapErrorPoll,
        onTapError: onTapError,
      )
    }

    /// Thread Domain: receiverQueue
    /// swift-format-ignore
    static func receiverLoopSync(
      buffers: [SPSCRingBuffer<Float>],
      timing: SPSCRingBuffer<TimingPacket>,
      processingFormat: AVAudioFormat,
      bufferReceivers: Synchronized<[any BufferReceiver<Float>]>,
      control: ReceiverControl,
      cadence: Duration,
      onUnderrun: (@Sendable () -> Void)?,
      onDrop: (@Sendable () -> Void)?,
      tapErrorPoll: (@Sendable () -> TapErrorCode?)?,
      onTapError: (@Sendable (TapErrorCode) -> Void)?,
    ) {
      RecordingEngineRuntime.receiverLoopSync(
        buffers: buffers,
        timing: timing,
        processingFormat: processingFormat,
        bufferReceivers: bufferReceivers,
        control: control,
        cadence: cadence,
        onUnderrun: onUnderrun,
        onDrop: onDrop,
        tapErrorPoll: tapErrorPoll,
        onTapError: onTapError,
      )
    }

    /// Thread Domain: writerQueue
    ///
    /// - Parameter reusableBuffer: A pre-allocated buffer to reuse across calls,
    ///   eliminating per-chunk `AVAudioPCMBuffer` heap allocations. If `nil`,
    ///   a new buffer is allocated (fallback for edge cases).
    package static func flushChunk(
      size bufferSize: Int,
      from audioBuffers: [SPSCRingBuffer<Float>],
      in audioFormat: AVAudioFormat,
      to writer: any RecordingFileWriter,
      using reusableBuffer: AVAudioPCMBuffer? = nil,
      clock: ContinuousClock = .continuous,
    ) -> Result<WriteResult, any Error> {
      RecordingEngineRuntime.flushChunk(
        size: bufferSize,
        from: audioBuffers,
        in: audioFormat,
        to: writer,
        using: reusableBuffer,
        clock: clock,
      )
    }

    static func minimumAvailableFrames(
      channelCount: Int,
      audioBuffers: [SPSCRingBuffer<Float>],
      limit: Int,
    ) -> Int {
      RecordingEngineRuntime.minimumAvailableFrames(
        channelCount: channelCount,
        audioBuffers: audioBuffers,
        limit: limit,
      )
    }

    package static func minimumAvailableWriteFrames(
      channelCount: Int,
      audioBuffers: [SPSCRingBuffer<Float>],
      limit: Int,
    ) -> Int {
      RecordingEngineRuntime.minimumAvailableWriteFrames(
        channelCount: channelCount,
        audioBuffers: audioBuffers,
        limit: limit,
      )
    }

    /// Stops the current recording and returns the URL of the recorded file.
    ///
    /// - Returns: The URL of the recorded file.
    /// - Throws: A ``RecordingError/notRecording`` error if the engine is not currently recording.
    @MainActor
    public func stopRecording() async throws(RecordingError) -> URL {
      try await recordingRuntime.stopRecording()
    }

    nonisolated func isWriterDrainTimeout(_ failure: WriteFailure) -> Bool {
      recordingEngineRuntime.isWriterDrainTimeout(failure)
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
    /// - Throws: ``RecordingError/notRecording`` if not currently recording
    @MainActor
    public func rotateRecordingFile() async throws(RecordingError) -> URL {
      try await recordingRuntime.rotateRecordingFile()
    }
  }
#endif
