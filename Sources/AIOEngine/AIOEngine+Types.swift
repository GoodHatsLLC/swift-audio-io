#if canImport(AVFoundation)
  import AVFoundation
  import Atomics
  import Tools

  struct EmptyAudioFileError: LocalizedError, Equatable, Sendable {
    let url: URL

    var errorDescription: String? {
      "Audio file is empty: \(url.lastPathComponent)"
    }
  }

  struct MissingAudioFileError: LocalizedError, Equatable, Sendable {
    let url: URL

    var errorDescription: String? {
      "Audio file is missing: \(url.lastPathComponent)"
    }
  }

  enum WriterBackend: Equatable, Sendable {
    case avAudioFile
    case extAudioFile
  }

  protocol RecordingFileWriter: Sendable {
    var fileURL: URL { get }
    func write(_ buffer: AVAudioPCMBuffer) throws
    func close()
  }

  // SAFETY: AVAudioFile is only accessed serially from the audio writer thread via WriterControl.
  final class AVAudioFileWriter: @unchecked Sendable, RecordingFileWriter {
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

  // SAFETY: ExtAudioFileRef is only accessed serially from the audio writer thread via WriterControl.
  @safe final class ExtAudioFileWriter: @unchecked Sendable, RecordingFileWriter {
    let fileURL: URL
    private var file: ExtAudioFileRef?

    init(
      url: URL,
      fileType: AudioFileTypeID,
      outputFormat: AVAudioFormat,
      clientFormat: AVAudioFormat
    ) throws {
      self.fileURL = url
      var asbd = unsafe outputFormat.streamDescription.pointee
      var newFile: ExtAudioFileRef?
      let status = unsafe ExtAudioFileCreateWithURL(
        url as CFURL,
        fileType,
        &asbd,
        nil,
        AudioFileFlags.eraseFile.rawValue,
        &newFile
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
        &clientASBD
      )
      guard setStatus == noErr else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(setStatus), userInfo: nil)
      }
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
      guard let file = unsafe file else { return }
      let frames = buffer.frameLength
      let status = unsafe ExtAudioFileWrite(file, frames, buffer.audioBufferList)
      guard status == noErr else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
      }
    }

    func close() {
      if let file = unsafe file {
        unsafe ExtAudioFileDispose(file)
        unsafe self.file = nil
      }
    }
  }

  struct WriterDrainTimeoutError: LocalizedError, Equatable, Sendable {
    let url: URL?
    let timeout: Duration

    var errorDescription: String? {
      "Writer drain timed out after \(timeout.seconds) seconds for \(url?.lastPathComponent ?? "missing URL")"
    }
  }

  actor WriterDrainSignal {
    private var isSignaled = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    func isSignaledValue() -> Bool {
      isSignaled
    }

    func wait() async {
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
          Task { await self.cancelWaiter(waiterID) }
        })
    }

    private func cancelWaiter(_ waiterID: UUID) {
      guard let continuation = continuations.removeValue(forKey: waiterID) else { return }
      continuation.resume()
    }

    func signal() {
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
  final class WriterControl: @unchecked Sendable {
    let stopRequested = ManagedAtomic<Bool>(false)
    let cancelRequested = ManagedAtomic<Bool>(false)
    let drainSignal = WriterDrainSignal()
    let targetSatisfiedSignal = WriterDrainSignal()
    let writtenSampleTime = ManagedAtomic<Int64>(0)
    let targetSampleTime = ManagedAtomic<Int64>(0)
  }

  struct WriterSession: Sendable {
    let id: UUID
    let control: WriterControl
    let writer: any RecordingFileWriter
    let fileURL: URL
  }

  // SAFETY: Sole field is a ManagedAtomic<Bool> — inherently thread-safe.
  final class ReceiverControl: @unchecked Sendable {
    let cancelRequested = ManagedAtomic<Bool>(false)
  }

  struct ReceiverSession: Sendable {
    let id: UUID
    let control: ReceiverControl
    let buffers: [SPSCRingBuffer<Float>]
    let timing: SPSCRingBuffer<TimingPacket>
    let processingFormat: AVAudioFormat
  }

  struct TimingPacket: Equatable, Sendable {
    let startSampleTime: Int64
    let frameCount: Int
    let hostTime: UInt64?
    let sourceSampleTime: Int64?
    let sourceSampleRate: Double?
  }

  struct InternalState {
    var recordingWriter: (any RecordingFileWriter)?
    var recordingURL: URL?
    var recordingConfiguration: RecordingConfiguration?
    var playbackInstance: PlaybackInstance?
    var installedTapBus: Int?
    var audioBuffers: [SPSCRingBuffer<Float>]?
    var receiverBuffers: [SPSCRingBuffer<Float>]?
    var receiverTiming: SPSCRingBuffer<TimingPacket>?
    var tapConverter: AVAudioConverter?
    var tapConverterInputFormat: AVAudioFormat?
    var tapConverterOutputFormat: AVAudioFormat?
    var tapConvertedBuffer: AVAudioPCMBuffer?
  }

  // MARK: - Tap Snapshot (Lock-Free Tap State)

  /// A snapshot of the fields `processAudio()` reads from `InternalState`.
  ///
  /// This struct enables a lock-free read path on the tap thread. The configuration
  /// thread writes a new snapshot under the lock; the tap thread reads a cached copy
  /// without blocking when the lock is contended.
  struct TapSnapshot {
    let audioBuffers: [SPSCRingBuffer<Float>]?
    let receiverBuffers: [SPSCRingBuffer<Float>]?
    let receiverTiming: SPSCRingBuffer<TimingPacket>?
    let converter: AVAudioConverter?
    let converterInputFormat: AVAudioFormat?
    let converterOutputFormat: AVAudioFormat?
    let convertedBuffer: AVAudioPCMBuffer?

    static var empty: TapSnapshot {
      TapSnapshot(
        audioBuffers: nil,
        receiverBuffers: nil,
        receiverTiming: nil,
        converter: nil,
        converterInputFormat: nil,
        converterOutputFormat: nil,
        convertedBuffer: nil
      )
    }
  }

  struct EngineMetrics: Sendable {
    #if DEBUG
      let tapCallbackCount = ManagedAtomic<Int64>(0)
      let tapCallbackMaxNanos = ManagedAtomic<UInt64>(0)
      let writerUnderruns = ManagedAtomic<Int64>(0)
      let writerStallCount = ManagedAtomic<Int64>(0)
      let receiverUnderruns = ManagedAtomic<Int64>(0)
      let writerDrops = ManagedAtomic<Int64>(0)
      let receiverDrops = ManagedAtomic<Int64>(0)
    #endif
  }

  enum WriterDrainOutcome: Equatable, Sendable {
    case signaled
    case targetSatisfied
    case timedOut
  }

  enum TapErrorCode: Int, Equatable, Sendable {
    case converterMissing = 1
    case bufferTooSmall = 2
    case conversionFailed = 3
  }

  struct PlaybackInstance: Identifiable {
    let id: UUID
    let file: AVAudioFile
    let startFrame: AVAudioFramePosition
    let pollingInterval: Duration
  }

  struct PlaybackResume: Equatable, Sendable {
    let fileURL: URL
    let time: TimeInterval
    let duration: TimeInterval
    let wasPlaying: Bool
    let pollingInterval: Duration
  }

  struct WriteFailure: Equatable, Sendable {
    let url: URL?
    let error: ErrorContext
  }

  struct WriteResult: Equatable, Sendable {
    let framesRead: Int
    let writeDuration: Duration?
  }

  #if os(iOS)
    typealias OutputFileProtection = FileProtectionType
  #else
    typealias OutputFileProtection = Never
  #endif
#endif
