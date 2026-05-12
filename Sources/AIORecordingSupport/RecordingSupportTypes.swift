// © GoodHatsLLC

#if canImport(AVFoundation)
  package import AIOAudioSession
  package import Atomics
  import AudioToolbox
  package import AVFoundation
  package import Dispatch
  package import Foundation
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
    package init(id: UUID, control: WriterControl, writer: any RecordingFileWriter, fileURL: URL) {
      self.id = id
      self.control = control
      self.writer = writer
      self.fileURL = fileURL
    }

    package let id: UUID
    package let control: WriterControl
    package let writer: any RecordingFileWriter
    package let fileURL: URL
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

  package struct RecordingState {
    package var recordingWriter: (any RecordingFileWriter)?
    package var recordingURL: URL?
    package var recordingConfiguration: RecordingConfiguration?
    package var installedTapBus: Int?
    package var audioBuffers: [SPSCRingBuffer<Float>]?
    package var receiverBuffers: [SPSCRingBuffer<Float>]?
    package var receiverTiming: SPSCRingBuffer<TimingPacket>?
    package var tapConverter: AVAudioConverter?
    package var tapConverterInputFormat: AVAudioFormat?
    package var tapConverterOutputFormat: AVAudioFormat?
    package var tapConvertedBuffer: AVAudioPCMBuffer?
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

  package struct RecordingRuntimeState {
    package var reconciliationConfiguration: ReconciliationConfiguration = .default
    package var recordingSessionConfiguration: AudioSessionConfiguration = .recordingConfiguration
    package var writerBackend: WriterBackend = .extAudioFile
    package var deactivateAudioSessionOnStop = false
    package var lastRecordingConfiguration: RecordingConfiguration?
    package var pendingRecordingRestart: RecordingConfiguration?
    package var receiverSession: ReceiverSession?
    package var reconciliationTask: MainActorOwnedWork?
    package var writerSession: WriterSession?
    package var drainingWriterSessions: [WriterSession] = []
    package var lastWriteFailure: WriteFailure?
    package var lastRecordingStartFailure: (any Error)?

    package init() {}
  }

  // SAFETY: This groups the existing recording-only synchronized primitives, queues, and atomics.
  // Ownership remains behaviorally identical to the previous AIOEngine stored-property layout.
  package final class RecordingInfrastructure: @unchecked Sendable {
    package let writerQueue = DispatchQueue(label: "AIOEngine.writer", qos: .userInitiated)
    package let receiverQueue = DispatchQueue(label: "AIOEngine.receiver", qos: .userInitiated)
    package let recordingSampleTimeAtomic = ManagedAtomic<Int64>(0)
    package let writerDrainTimeout: Duration = .seconds(5)
    package let stopDrainTimeout: Duration = .seconds(6)
    package let receiverPollingInterval: Duration = .milliseconds(20)
    package let maxBufferSeconds: Double = 2.0
    package let tapErrorCode = ManagedAtomic<Int>(0)
    package let tapResizeRequestedFrames = ManagedAtomic<Int>(0)
    package let metrics = EngineMetrics()
    package let state: Synchronized<RecordingState> = .init(.init())
    package let tapSnapshotLock = Mut<TapSnapshot>(.empty)

    package init() {}
  }
#endif
