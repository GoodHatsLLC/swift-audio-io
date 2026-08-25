// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOAudioSession
  package import Atomics
  import AudioToolbox
  package import AVFoundation
  package import Dispatch
  package import Foundation
  import Observation
  package import Tools

  package enum WriterBackend: Equatable {
    case avAudioFile
    case extAudioFile
  }

  package protocol RecordingFileWriter: Sendable {
    var fileURL: URL { get }
    func write(_ buffer: AVAudioPCMBuffer) throws
    func close()
  }

  // SAFETY: AVAudioFile is only accessed serially from the audio writer thread via WriterControl.
  package final class AVAudioFileWriter: @unchecked Sendable, RecordingFileWriter {
    package let file: AVAudioFile
    package let fileURL: URL

    package init(file: AVAudioFile) {
      self.file = file
      fileURL = file.url
    }

    package func write(_ buffer: AVAudioPCMBuffer) throws {
      try file.write(from: buffer)
    }

    package func close() {
      file.close()
    }
  }

  // SAFETY: ExtAudioFileRef is only accessed serially from the audio writer thread via WriterControl.
  @safe package final class ExtAudioFileWriter: @unchecked Sendable, RecordingFileWriter {
    package let fileURL: URL
    private var file: ExtAudioFileRef?

    package init(
      url: URL,
      fileType: AudioFileTypeID,
      outputFormat: AVAudioFormat,
      clientFormat: AVAudioFormat,
    ) throws {
      fileURL = url
      var asbd = unsafe outputFormat.streamDescription.pointee
      var newFile: ExtAudioFileRef?
      let status = unsafe ExtAudioFileCreateWithURL(
        url as CFURL,
        fileType,
        &asbd,
        nil,
        AudioFileFlags.eraseFile.rawValue,
        &newFile,
      )
      guard status == noErr, let created = unsafe newFile else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
      }
      unsafe file = unsafe created
      var clientASBD = unsafe clientFormat.streamDescription.pointee
      let propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      let setStatus = unsafe ExtAudioFileSetProperty(
        created,
        kExtAudioFileProperty_ClientDataFormat,
        propertySize,
        &clientASBD,
      )
      guard setStatus == noErr else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(setStatus), userInfo: nil)
      }
    }

    package func write(_ buffer: AVAudioPCMBuffer) throws {
      guard let file = unsafe file else { return }
      let frames = buffer.frameLength
      let status = unsafe ExtAudioFileWrite(file, frames, buffer.audioBufferList)
      guard status == noErr else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
      }
    }

    package func close() {
      if let file = unsafe file {
        unsafe ExtAudioFileDispose(file)
        unsafe self.file = nil
      }
    }
  }

  package struct WriterDrainTimeoutError: LocalizedError, Equatable {
    package init(url: URL?, timeout: Duration) {
      self.url = url
      self.timeout = timeout
    }

    package let url: URL?
    package let timeout: Duration

    package var errorDescription: String? {
      "Writer drain timed out after \(timeout.seconds) seconds for \(url?.lastPathComponent ?? "missing URL")"
    }
  }

  package actor WriterDrainSignal {
    private nonisolated let cancellationRunner = AsyncTaskRunner()
    private var isSignaled = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    package func isSignaledValue() -> Bool {
      isSignaled
    }

    package func wait() async {
      if isSignaled { return }
      let waiterID = UUID()
      await withTaskCancellationHandler(
        operation: {
          await withCheckedContinuation { continuation in
            if isSignaled || Task.isCancelled {
              continuation.resume()
              return
            }
            continuations[waiterID] = continuation
          }
        },
        onCancel: {
          cancellationRunner.run {
            await self.cancelWaiter(waiterID)
          }
        },
      )
    }

    private func cancelWaiter(_ waiterID: UUID) {
      guard let continuation = continuations.removeValue(forKey: waiterID) else { return }
      continuation.resume()
    }

    package nonisolated func signalFromSynchronousContext() {
      cancellationRunner.run {
        await self.signal()
      }
    }

    package func signal() {
      guard !isSignaled else { return }
      isSignaled = true
      let pending = Array(continuations.values)
      continuations.removeAll()
      for continuation in pending {
        continuation.resume()
      }
    }
  }

  // SAFETY: All fields are ManagedAtomic or an actor (WriterDrainSignal) — inherently thread-safe.
  package final class WriterControl: @unchecked Sendable {
    package init() {}

    package let stopRequested = ManagedAtomic<Bool>(false)
    package let cancelRequested = ManagedAtomic<Bool>(false)
    package let drainSignal = WriterDrainSignal()
    package let targetSatisfiedSignal = WriterDrainSignal()
    package let writtenSampleTime = ManagedAtomic<Int64>(0)
    package let targetSampleTime = ManagedAtomic<Int64>(0)
  }

  package struct WriterSession {
    package init(
      id: UUID,
      control: WriterControl,
      writer: any RecordingFileWriter,
      fileURL: URL,
      startFramePosition: Int64,
    ) {
      self.id = id
      self.control = control
      self.writer = writer
      self.fileURL = fileURL
      self.startFramePosition = startFramePosition
    }

    package let id: UUID
    package let control: WriterControl
    package let writer: any RecordingFileWriter
    package let fileURL: URL

    /// Cumulative persisted-frame position at which this file begins — the
    /// boundary reported by the rotation that opened it, and `0` for the first
    /// file of a capture.
    ///
    /// Drain targets are sampled from the capture-wide counter, so the
    /// session's own progress (`control.writtenSampleTime`) is kept in that
    /// same domain by starting it here. Without the offset, every file after
    /// the first is measured against a target it can never reach.
    package let startFramePosition: Int64
  }

  // SAFETY: Sole field is a ManagedAtomic<Bool> — inherently thread-safe.
  package final class ReceiverControl: @unchecked Sendable {
    package init() {}

    package let cancelRequested = ManagedAtomic<Bool>(false)
  }

  package struct ReceiverSession {
    package init(
      id: UUID,
      control: ReceiverControl,
      buffers: [SPSCRingBuffer<Float>],
      timing: SPSCRingBuffer<TimingPacket>,
      processingFormat: AVAudioFormat,
    ) {
      self.id = id
      self.control = control
      self.buffers = buffers
      self.timing = timing
      self.processingFormat = processingFormat
    }

    package let id: UUID
    package let control: ReceiverControl
    package let buffers: [SPSCRingBuffer<Float>]
    package let timing: SPSCRingBuffer<TimingPacket>
    package let processingFormat: AVAudioFormat
  }

  package struct TimingPacket: Equatable {
    package init(
      startSampleTime: Int64,
      frameCount: Int,
      hostTime: UInt64?,
      sourceSampleTime: Int64?,
      sourceSampleRate: Double?,
    ) {
      self.startSampleTime = startSampleTime
      self.frameCount = frameCount
      self.hostTime = hostTime
      self.sourceSampleTime = sourceSampleTime
      self.sourceSampleRate = sourceSampleRate
    }

    package let startSampleTime: Int64
    package let frameCount: Int
    package let hostTime: UInt64?
    package let sourceSampleTime: Int64?
    package let sourceSampleRate: Double?
  }

  /// How an active capture source should stop producing samples.
  package enum RecordingCaptureStopMode: Sendable {
    /// Stop delivery while allowing the shared writer pipeline to drain.
    case graceful
    /// Abort delivery and release source resources immediately.
    case immediate
  }

  /// Internal capture-source lifecycle boundary. The common recording machinery
  /// (output URL/writer, ring buffers, receiver timing, event emission, state)
  /// is shared; every prepared source owns start/stop/cleanup behind this
  /// contract.
  package protocol RecordingCaptureBackend: Sendable {
    /// Begin delivering buffers into the shared pipeline.
    func start() throws(RecordingError)

    /// Stop delivering buffers according to the caller's lifecycle intent.
    @MainActor func stop(mode: RecordingCaptureStopMode)

    /// Finalize resources that remain after `stop(mode:)`. The operation is
    /// best-effort, non-throwing, and idempotent.
    @MainActor func cleanup()
  }

  package struct RecordingState {
    package var recordingWriter: (any RecordingFileWriter)?
    /// The prepared capture source, or `nil` while no source is staged. Both
    /// microphone and system-audio capture use this lifecycle boundary.
    package var captureBackend: (any RecordingCaptureBackend)?
    package var recordingURL: URL?
    /// Whether the current output path did not exist before this start attempt
    /// opened it. Failed/cancelled startup removes only such newly-created files.
    package var recordingOutputWasCreatedByStart = false
    /// The staged configuration with an exact sample rate — a `.hardware`
    /// request after resolution against the live route. All format math
    /// (processing format, file settings, tap reinstalls) reads this.
    package var recordingConfiguration: RecordingConfiguration?
    /// The configuration exactly as the caller supplied it. Identity checks
    /// and interruption restarts use this so a `.hardware` request
    /// re-resolves against whatever route exists at restart. Written and
    /// cleared together with ``recordingConfiguration``.
    package var requestedRecordingConfiguration: RecordingConfiguration?
    package var installedTapBus: Int?
    /// How the staged request was satisfied against live hardware: the tap's
    /// installed format vs the processing/file format. Refreshed on every tap
    /// (re)install, so a route change that moves the hardware rate is
    /// reflected here; the file rate never moves mid-recording.
    package var captureResolution: ResolvedCaptureFormat?
    package var audioBuffers: [SPSCRingBuffer<Float>]?
    package var receiverBuffers: [SPSCRingBuffer<Float>]?
    package var receiverTiming: SPSCRingBuffer<TimingPacket>?
    package var tapConverter: AVAudioConverter?
    package var tapConverterInputFormat: AVAudioFormat?
    package var tapConverterOutputFormat: AVAudioFormat?
    package var tapConvertedBuffer: AVAudioPCMBuffer?
    /// What bring-up changed about the request in order to start, accumulated
    /// across the attempts of one awaited start and published through
    /// ``captureResolution``. Reset when a start operation begins.
    package var captureSubstitutions: [CaptureSubstitution] = []
    /// Set for the final attempt of a start whose deadline expired while the
    /// route had not yet switched to the preferred input: that attempt begins
    /// capture on the current input instead of failing.
    package var toleratesPreferredInputMismatch = false
  }

  package struct TapConversionArtifacts {
    package init(
      converter: AVAudioConverter,
      inputFormat: AVAudioFormat,
      convertedBuffer: AVAudioPCMBuffer,
    ) {
      self.converter = converter
      self.inputFormat = inputFormat
      self.convertedBuffer = convertedBuffer
    }

    package let converter: AVAudioConverter
    package let inputFormat: AVAudioFormat
    package let convertedBuffer: AVAudioPCMBuffer
  }

  package struct TapInstallResult {
    package init(
      tapFormat: AVAudioFormat,
      artifacts: TapConversionArtifacts,
      tapConfiguration: TapConfiguration,
    ) {
      self.tapFormat = tapFormat
      self.artifacts = artifacts
      self.tapConfiguration = tapConfiguration
    }

    package let tapFormat: AVAudioFormat
    package let artifacts: TapConversionArtifacts
    package let tapConfiguration: TapConfiguration
  }

  /// Installs the input tap for one prepared microphone recording.
  ///
  /// This is the seam between the recording lifecycle and `AVAudioEngine`'s
  /// graph. The lifecycle owns everything around the tap — validation, ring
  /// buffers, the writer, the output URL, event emission — and reaches
  /// through here for the one step that requires a live audio graph, so tests
  /// can exercise the real lifecycle without one.
  package protocol TapInstalling: Sendable {
    @MainActor
    func installTap(
      configuration: RecordingConfiguration,
      processingFormat: AVAudioFormat,
    ) throws(RecordingError) -> TapInstallResult

    /// The input format a ``RecordingSampleRate/hardware`` request resolves
    /// against when the installer can answer without a live graph. `nil`
    /// defers to the engine's hardware read. The fake reports the tap format
    /// it would advertise on its next install, so `.hardware` bring-up is
    /// deterministic in tests.
    @MainActor
    var hardwareInputFormat: AVAudioFormat? { get }
  }

  extension TapInstalling {
    @MainActor
    package var hardwareInputFormat: AVAudioFormat? { nil }
  }

  package struct TapSnapshot {
    package init(
      audioBuffers: [SPSCRingBuffer<Float>]?,
      receiverBuffers: [SPSCRingBuffer<Float>]?,
      receiverTiming: SPSCRingBuffer<TimingPacket>?,
      converter: AVAudioConverter?,
      converterInputFormat: AVAudioFormat?,
      converterOutputFormat: AVAudioFormat?,
      convertedBuffer: AVAudioPCMBuffer?,
    ) {
      self.audioBuffers = audioBuffers
      self.receiverBuffers = receiverBuffers
      self.receiverTiming = receiverTiming
      self.converter = converter
      self.converterInputFormat = converterInputFormat
      self.converterOutputFormat = converterOutputFormat
      self.convertedBuffer = convertedBuffer
    }

    package let audioBuffers: [SPSCRingBuffer<Float>]?
    package let receiverBuffers: [SPSCRingBuffer<Float>]?
    package let receiverTiming: SPSCRingBuffer<TimingPacket>?
    package let converter: AVAudioConverter?
    package let converterInputFormat: AVAudioFormat?
    package let converterOutputFormat: AVAudioFormat?
    package let convertedBuffer: AVAudioPCMBuffer?

    package static var empty: TapSnapshot {
      TapSnapshot(
        audioBuffers: nil,
        receiverBuffers: nil,
        receiverTiming: nil,
        converter: nil,
        converterInputFormat: nil,
        converterOutputFormat: nil,
        convertedBuffer: nil,
      )
    }
  }

  package struct EngineMetrics {
    #if DEBUG
      package let tapCallbackCount = ManagedAtomic<Int64>(0)
      package let tapCallbackMaxNanos = ManagedAtomic<UInt64>(0)
      package let writerUnderruns = ManagedAtomic<Int64>(0)
      package let writerStallCount = ManagedAtomic<Int64>(0)
      package let receiverUnderruns = ManagedAtomic<Int64>(0)
      package let writerDrops = ManagedAtomic<Int64>(0)
      package let receiverDrops = ManagedAtomic<Int64>(0)
    #endif
  }

  package enum WriterDrainOutcome: Equatable {
    case signaled
    case targetSatisfied
    case timedOut
  }

  package enum TapErrorCode: Int, Equatable {
    case converterMissing = 1
    case bufferTooSmall = 2
    case conversionFailed = 3
  }

  package struct WriteFailure: Equatable {
    package init(url: URL?, error: ErrorContext) {
      self.url = url
      self.error = error
    }

    package let url: URL?
    package let error: ErrorContext
  }

  package struct WriteResult: Equatable {
    package init(framesRead: Int, writeDuration: Duration?) {
      self.framesRead = framesRead
      self.writeDuration = writeDuration
    }

    package let framesRead: Int
    package let writeDuration: Duration?
  }

  #if os(iOS)
    package typealias OutputFileProtection = FileProtectionType
  #else
    package typealias OutputFileProtection = Never
  #endif

  /// Main-actor state owned by the recording lifecycle.
  ///
  /// `isRecording` is observable through `AIOEngine.isRecording`; the remaining
  /// fields are lifecycle implementation state shared by its concrete helpers.
  @Observable
  @MainActor
  package final class RecordingLifecycleState {
    package var isRecording = false
    package var isStartingRecording = false
    package var startAbortRequested = false
    package var startOperationID: UUID?
    package var recordingSessionConfiguration: AudioSessionConfiguration = .recordingConfiguration
    package var writerBackend: WriterBackend = .extAudioFile
    package var lastRecordingConfiguration: RecordingConfiguration?
    package var receiverSession: ReceiverSession?
    /// In-flight async tap-interval reconfigure scheduled by
    /// `updateRecordingTapInterval` (kept sync). Stored so a stop/teardown can
    /// cancel a pending reinstall rather than letting it run against a torn-down
    /// graph; the on-queue teardown guard + post-await re-check are the
    /// authoritative safety net, this is best-effort early cancellation.
    package var tapIntervalReconfigureTask: MainActorOwnedWork? {
      didSet {
        oldValue?.cancelNow()
      }
    }
    package var writerSession: WriterSession?
    package var drainingWriterSessions: [WriterSession] = []
    package var lastWriteFailure: WriteFailure?

    package nonisolated init() {}
  }

  // SAFETY: This groups the existing recording-only synchronized primitives, queues, and atomics.
  // Ownership remains behaviorally identical to the previous AIOEngine stored-property layout.
  package final class RecordingInfrastructure: @unchecked Sendable {
    package let writerQueue = DispatchQueue(label: "AIOEngine.writer", qos: .userInitiated)
    package let receiverQueue = DispatchQueue(label: "AIOEngine.receiver", qos: .userInitiated)
    package let recordingSampleTimeAtomic = ManagedAtomic<Int64>(0)
    /// Mach host time (`mach_absolute_time` domain) of the first captured frame of the current
    /// recording segment that carried a valid host time. `0` means "not captured yet". Written once
    /// per segment from the real-time tap thread and reset to `0` on each start. Used to
    /// anchor a recording for cross-device alignment (see `RecordingTimingSnapshot`).
    package let recordingFirstHostTimeAtomic = ManagedAtomic<UInt64>(0)
    /// Source (hardware) sample index paired with `recordingFirstHostTimeAtomic`. `Int64.min` means
    /// "no valid source sample time for the first host-timed frame". Stored before the host-time
    /// store so a reader observing a non-zero host time also observes this value.
    package let recordingFirstSourceSampleTimeAtomic = ManagedAtomic<Int64>(Int64.min)
    /// Mach host time of the first frame in the latest persisted buffer that carried valid host
    /// time. Published after `recordingHostTimeSpanFrameCountAtomic` is updated.
    package let recordingLastHostTimeAtomic = ManagedAtomic<UInt64>(0)
    /// Exact frames accepted by the recording writer during the current segment.
    package let recordingCapturedFrameCountAtomic = ManagedAtomic<UInt64>(0)
    /// Writer-frame position immediately before the first host-timed persisted buffer.
    package let recordingFirstHostFramePositionAtomic = ManagedAtomic<UInt64>(0)
    /// Persisted frames between the first and latest host-timed buffer starts.
    package let recordingHostTimeSpanFrameCountAtomic = ManagedAtomic<UInt64>(0)
    package let writerDrainTimeout: Duration = .seconds(5)
    package let stopDrainTimeout: Duration = .seconds(6)
    package let receiverPollingInterval: Duration = .milliseconds(20)
    package let maxBufferSeconds: Double = 2.0
    package let tapErrorCode = ManagedAtomic<Int>(0)
    package let tapResizeRequestedFrames = ManagedAtomic<Int>(0)
    /// Engine-teardown serialization sentinel.
    ///
    /// Set to `true` by a teardown (`gracefulStop()` / `hardStop()`) **before**
    /// it enqueues its `engineControlQueue` teardown work, and cleared back to
    /// `false` by a fresh bring-up (`prepareRecordingGraph` / `prepareSystemAudioGraph`)
    /// from **on** the engine-control queue. A tap reinstall checks this flag at
    /// the top of its on-queue body and bails before mutating the graph when a
    /// teardown has superseded it — the engine-control queue being the only
    /// point serialized against the teardown. This prevents a route-change /
    /// tap-interval reinstall that lost the race to a concurrent stop from
    /// reinstalling a live tap onto a torn-down/stopped graph. See
    /// `docs/plans/2026-06-22-main-thread-citizen.md` (Chunk 0).
    package let engineTearingDown = ManagedAtomic<Bool>(false)
    package let metrics = EngineMetrics()
    package let state: Synchronized<RecordingState> = .init(.init())
    package let tapSnapshotLock = Mut<TapSnapshot>(.empty)

    package init() {}
  }
#endif
