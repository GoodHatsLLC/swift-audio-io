import Foundation

/// A protocol for objects that can receive and process buffers of audio data.
public protocol BufferReceiver<T>: AnyObject, Sendable {
  associatedtype T
  /// Processes a buffer of audio data.
  ///
  /// This method is called on a real-time audio thread. Implementations should be fast and non-blocking.
  ///
  /// - Parameter data: A buffer pointer to the audio data.
  nonisolated func processBuffer(_ data: UnsafeBufferPointer<T>)

  /// Processes a buffer of audio data with timing information.
  ///
  /// This method is called on a real-time audio thread. Implementations should be fast and non-blocking.
  ///
  /// - Parameters:
  ///   - data: A buffer pointer to the audio data.
  ///   - timing: Timing information for the start of `data` in the receiver's sample domain.
  nonisolated func processBuffer(_ data: UnsafeBufferPointer<T>, timing: BufferTiming)
  /// Called when the buffer task is ending.
  ///
  /// This method is called when the audio engine is stopping, and no more buffers will be received.
  /// Use this method to clean up any resources.
  nonisolated func endBufferTask()
}

/// A token-scoped buffer receiver subscription.
///
/// Invalidating the token detaches the receiver associated with this
/// registration. The token also invalidates itself on deinitialization, so a
/// dropped token does not leave the receiver registered indefinitely.
// SAFETY: Mutable state is guarded by `lock`; the stored `@Sendable` cancellation closure is released under the lock before it is invoked.
public final class BufferReceiverToken: @unchecked Sendable {
  private let lock = NSLock()
  private var onInvalidate: (@Sendable () -> Void)?

  public init(_ onInvalidate: @escaping @Sendable () -> Void = {}) {
    self.onInvalidate = onInvalidate
  }

  deinit {
    invalidate()
  }

  public func invalidate() {
    let action: (@Sendable () -> Void)?
    lock.lock()
    action = onInvalidate
    onInvalidate = nil
    lock.unlock()

    action?()
  }
}

extension BufferReceiver {
  public nonisolated func processBuffer(_ data: UnsafeBufferPointer<T>, timing _: BufferTiming) {
    unsafe processBuffer(data)
  }
}

/// Timing information associated with a received audio buffer.
///
/// `sampleTime` is expressed in the receiver's sample domain (i.e. the sample rate of the provided buffer).
/// The optional `source*` fields may provide the upstream tap's timing (if available).
public struct BufferTiming: Sendable, Equatable {
  /// The sample time (frame position) of the first sample in the buffer.
  public let sampleTime: Int64

  /// The sample rate of the buffer's sample domain.
  public let sampleRate: Double

  /// The host time (mach absolute time units) for the buffer, if provided by the source.
  public let hostTime: UInt64?

  /// The source (tap) sample time for the buffer, if provided by the source.
  public let sourceSampleTime: Int64?

  /// The source (tap) sample rate for the buffer, if provided by the source.
  public let sourceSampleRate: Double?

  public init(
    sampleTime: Int64,
    sampleRate: Double,
    hostTime: UInt64? = nil,
    sourceSampleTime: Int64? = nil,
    sourceSampleRate: Double? = nil,
  ) {
    self.sampleTime = sampleTime
    self.sampleRate = sampleRate
    self.hostTime = hostTime
    self.sourceSampleTime = sourceSampleTime
    self.sourceSampleRate = sourceSampleRate
  }
}

/// A host-time anchor for a recording segment, used to align recordings captured on multiple
/// devices into a single multi-channel timeline.
///
/// The host-time fields are the `mach_absolute_time`-domain start times of the first and last
/// persisted buffers that carried valid host time. `hostTimeSpanFrameCount` is the exact number of
/// persisted frames between those two buffer starts, so callers can measure the effective capture
/// rate without estimating from file duration:
///
/// ```swift
/// effectiveSampleRate = hostTimeSpanFrameCount / hostTimeSpanSeconds
/// ```
///
/// The values are captured on the recording path and reset together at each recording start. Read
/// the snapshot immediately after `stopRecording()` for a complete, stable view of the
/// just-finished segment.
public struct RecordingTimingSnapshot: Sendable, Hashable {
  /// Host time (`mach_absolute_time` units) of the first captured frame with a valid host time.
  public let firstBufferHostTime: UInt64

  /// Source (hardware) sample index of that first frame, if the tap reported a valid source
  /// sample time; otherwise `nil`.
  public let firstBufferSampleTime: Int64?

  /// Host time of the first frame in the latest persisted buffer that carried a valid host time.
  /// Equal to `firstBufferHostTime` until a second host-timed buffer is persisted.
  public let lastBufferHostTime: UInt64

  /// Exact number of frames accepted by the recording writer for this segment, including buffers
  /// without valid host time. This describes persisted PCM, not merely frames presented by the
  /// capture callback.
  public let capturedFrameCount: UInt64

  /// Exact number of persisted frames between `firstBufferHostTime` and `lastBufferHostTime`.
  /// Divide this by the converted host-time interval to measure the effective sample rate. A value
  /// of zero means fewer than two distinct host-timed buffer starts were captured.
  public let hostTimeSpanFrameCount: UInt64

  public init(
    firstBufferHostTime: UInt64,
    firstBufferSampleTime: Int64? = nil,
    lastBufferHostTime: UInt64? = nil,
    capturedFrameCount: UInt64 = 0,
    hostTimeSpanFrameCount: UInt64 = 0,
  ) {
    self.firstBufferHostTime = firstBufferHostTime
    self.firstBufferSampleTime = firstBufferSampleTime
    self.lastBufferHostTime = lastBufferHostTime ?? firstBufferHostTime
    self.capturedFrameCount = capturedFrameCount
    self.hostTimeSpanFrameCount = hostTimeSpanFrameCount
  }
}

/// A protocol for objects that can emit buffers of audio data to receivers.
public protocol BufferEmitter<T>: AnyObject {
  associatedtype T
  /// Attaches a buffer receiver to the emitter.
  ///
  /// - Parameter receiver: The buffer receiver to attach.
  @discardableResult
  func attachBufferReceiver(_ receiver: some BufferReceiver<T>) async -> BufferReceiverToken
  /// Detaches all buffer receivers from the emitter.
  func detachBufferReceivers() async
}
