#if !os(macOS) || targetEnvironment(macCatalyst)
  @preconcurrency import AVFoundation
  import Atomics
  import Tools

  struct EmptyAudioFileError: LocalizedError, Sendable {
    let url: URL

    var errorDescription: String? {
      "Audio file is empty: \(url.lastPathComponent)"
    }
  }

  struct MissingAudioFileError: LocalizedError, Sendable {
    let url: URL

    var errorDescription: String? {
      "Audio file is missing: \(url.lastPathComponent)"
    }
  }

  enum WriterBackend: Sendable {
    case avAudioFile
    case extAudioFile
  }

  protocol RecordingFileWriter: Sendable {
    var fileURL: URL { get }
    func write(_ buffer: AVAudioPCMBuffer) throws
    func close()
  }

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

  final class ExtAudioFileWriter: @unchecked Sendable, RecordingFileWriter {
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

  struct WriterDrainTimeoutError: LocalizedError, Sendable {
    let url: URL?
    let timeout: Duration

    var errorDescription: String? {
      "Writer drain timed out after \(timeout.seconds) seconds for \(url?.lastPathComponent ?? "missing URL")"
    }
  }

  actor WriterDrainSignal {
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

  final class WriterControl: @unchecked Sendable {
    let stopRequested = ManagedAtomic<Bool>(false)
    let cancelRequested = ManagedAtomic<Bool>(false)
    let drainSignal = WriterDrainSignal()
    let writtenSampleTime = ManagedAtomic<Int64>(0)
    let targetSampleTime = ManagedAtomic<Int64>(0)
  }

  struct WriterSession: Sendable {
    let id: UUID
    let control: WriterControl
    let writer: RecordingFileWriter
    let fileURL: URL
  }

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

  struct TimingPacket: Sendable {
    let startSampleTime: Int64
    let frameCount: Int
    let hostTime: UInt64?
    let sourceSampleTime: Int64?
    let sourceSampleRate: Double?
  }

  struct InternalState {
    var recordingWriter: RecordingFileWriter?
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
    var isHandlingRouteChange: Bool = false
    var initialInputFormat: AVAudioFormat?
    var lastInputFormat: AVAudioFormat?
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

  enum WriterDrainOutcome: Sendable {
    case signaled
    case targetSatisfied
    case timedOut
  }

  enum TapErrorCode: Int, Sendable {
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

  struct PlaybackResume: Sendable {
    let fileURL: URL
    let time: TimeInterval
    let duration: TimeInterval
    let wasPlaying: Bool
    let pollingInterval: Duration
  }

  struct WriteFailure: Sendable {
    let url: URL?
    let error: ErrorContext
  }

  struct WriteResult: Sendable {
    let framesRead: Int
    let writeDuration: Duration?
  }

  #if os(iOS)
    typealias OutputFileProtection = FileProtectionType
  #else
    typealias OutputFileProtection = Never
  #endif
#endif
