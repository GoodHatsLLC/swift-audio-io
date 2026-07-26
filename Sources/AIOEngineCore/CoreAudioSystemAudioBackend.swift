// © GoodHatsLLC

#if os(macOS)
  import AIOAudioSession
  import AIOSupport
  import Atomics
  import AVFoundation
  import CoreAudio
  import Foundation
  import os
  import Tools

  private let log = SystemLog.make()

  /// Owns the Core Audio process-tap lifecycle: the tap, the private aggregate
  /// device, and the IOProc. The IOProc does nothing but a lock-free
  /// `SystemAudioSampleHandoff.enqueue` on the realtime thread.
  ///
  /// NOTE: tap/aggregate/IOProc creation requires the system-audio recording
  /// entitlement (`NSAudioCaptureUsageDescription`) and TCC permission, so this
  /// path is validated on-device, not in unit tests. The realtime handoff and the
  /// tap-description builder it depends on are unit-tested separately.
  // SAFETY: HAL object ids and the IOProc id are touched only via start/stop/
  // cleanup from the owning backend; the IOProc captures the Sendable handoff.
  @safe final class CoreAudioProcessTapSession: @unchecked Sendable {
    let sourceFormat: AVAudioFormat
    let maxIOFrames: Int
    let handoff: SystemAudioSampleHandoff

    private let tapID: AudioObjectID
    private let aggregateID: AudioObjectID
    private var ioProcID: AudioDeviceIOProcID?
    private var didStart = false
    private var didCleanup = false

    init(input: SystemAudioRecordingInput, capacitySeconds: Double) throws(RecordingError) {
      let currentProcessObjectID = SystemAudioProcessObjectID.currentProcess
      if input.excludesCurrentProcess, currentProcessObjectID == nil {
        // Self-exclusion by process object failed — the HAL has no process
        // object for this process (possible when it has not opened an audio
        // device yet). The tap description falls back to excluding the host
        // by bundle identifier; log it so any self-capture (the recorder
        // hearing its own playback) is diagnosable from logs.
        log.warning(
          "⚠️ No HAL process object for host; excluding own audio by bundle id fallback (\(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public))",
        )
      }
      let description = CoreAudioTapDescriptionBuilder.make(
        input: input,
        currentProcessObjectID: currentProcessObjectID,
        hostBundleIdentifier: Bundle.main.bundleIdentifier,
      )

      var tap = AudioObjectID(kAudioObjectUnknown)
      let tapStatus = unsafe AudioHardwareCreateProcessTap(description, &tap)
      guard tapStatus == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
        throw RecordingError.systemAudioStartupFailure(tapStatus, operation: "create process tap")
      }

      // Any failure past tap creation must destroy what was created so far.
      var createdAggregate: AudioObjectID?
      func unwind(_ error: RecordingError) -> RecordingError {
        if let createdAggregate { _ = AudioHardwareDestroyAggregateDevice(createdAggregate) }
        _ = AudioHardwareDestroyProcessTap(tap)
        return error
      }

      let format: AVAudioFormat
      let tapUID: String
      let aggregate: AudioObjectID
      let frames: Int
      do {
        format = try Self.readSourceFormat(tapID: tap)
        try Self.validate(format: format, requestedChannels: input.format.channels.count)
        tapUID = try Self.readTapUID(tapID: tap)
        aggregate = try Self.createAggregateDevice(input: input, tapUID: tapUID)
        createdAggregate = aggregate
        frames = try Self.bufferFrameSize(deviceID: aggregate)
      } catch {
        throw unwind(error)
      }

      guard
        let handoff = SystemAudioSampleHandoff(
          sourceFormat: format,
          maxIOFrames: frames,
          capacitySeconds: capacitySeconds,
        )
      else {
        throw unwind(
          .captureSourceFailed(
            sourceDescription: "systemAudio",
            details: "could not allocate sample handoff",
          ),
        )
      }

      tapID = tap
      aggregateID = aggregate
      sourceFormat = format
      maxIOFrames = frames
      self.handoff = handoff
    }

    /// Create + start the IOProc. Realtime-safe: the block only enqueues.
    func start() throws(RecordingError) {
      guard unsafe ioProcID == nil else { return }
      let handoff = self.handoff
      var procID: AudioDeviceIOProcID?
      let createStatus = unsafe AudioDeviceCreateIOProcIDWithBlock(
        &procID,
        aggregateID,
        nil,
      ) { _, inInputData, inInputTime, _, _ in
        _ = unsafe handoff.enqueue(inInputData, timeStamp: inInputTime)
      }
      guard createStatus == noErr, let procID = unsafe procID else {
        throw RecordingError.systemAudioStartupFailure(
          createStatus,
          operation: "create system audio IOProc",
        )
      }
      unsafe ioProcID = procID
      let startStatus = unsafe AudioDeviceStart(aggregateID, procID)
      guard startStatus == noErr else {
        throw RecordingError.systemAudioStartupFailure(
          startStatus,
          operation: "start system audio aggregate device",
        )
      }
      didStart = true
    }

    func stop() throws(RecordingError) {
      guard didStart, let procID = unsafe ioProcID else { return }
      let status = unsafe AudioDeviceStop(aggregateID, procID)
      didStart = false
      // Tolerate "not running" — the device may already be stopped.
      guard status == noErr || status == kAudioHardwareNotRunningError else {
        throw RecordingError.systemAudioStartupFailure(
          status,
          operation: "stop system audio aggregate device",
        )
      }
    }

    /// Best-effort, idempotent teardown in the order IOProc -> aggregate -> tap.
    func cleanup() {
      guard !didCleanup else { return }
      didCleanup = true
      if let procID = unsafe ioProcID {
        if didStart {
          _ = unsafe AudioDeviceStop(aggregateID, procID)
          didStart = false
        }
        _ = unsafe AudioDeviceDestroyIOProcID(aggregateID, procID)
        unsafe ioProcID = nil
      }
      _ = AudioHardwareDestroyAggregateDevice(aggregateID)
      _ = AudioHardwareDestroyProcessTap(tapID)
    }

    // MARK: - HAL helpers

    private static func readSourceFormat(tapID: AudioObjectID) throws(RecordingError)
      -> AVAudioFormat
    {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
      )
      var asbd = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      let status = unsafe AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
      guard status == noErr else {
        throw RecordingError.systemAudioStartupFailure(status, operation: "read tap format")
      }
      guard let format = unsafe AVAudioFormat(streamDescription: &asbd) else {
        throw RecordingError.captureSourceFailed(
          sourceDescription: "systemAudio",
          details: "tap format not representable as AVAudioFormat",
        )
      }
      return format
    }

    private static func validate(
      format: AVAudioFormat,
      requestedChannels: Int,
    ) throws(RecordingError) {
      let asbd = unsafe format.streamDescription.pointee
      guard asbd.mFormatID == kAudioFormatLinearPCM else {
        throw RecordingError.captureSourceFailed(
          sourceDescription: "systemAudio",
          details: "tap format is not linear PCM",
        )
      }
      guard format.sampleRate > 0 else {
        throw RecordingError.captureSourceFailed(
          sourceDescription: "systemAudio",
          details: "tap sample rate is zero",
        )
      }
      let channels = Int(format.channelCount)
      guard channels >= 1, channels <= 2 else {
        throw RecordingError.captureSourceFailed(
          sourceDescription: "systemAudio",
          details: "tap delivers \(channels) channels; only mono/stereo are supported",
        )
      }
    }

    private static func readTapUID(tapID: AudioObjectID) throws(RecordingError) -> String {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
      )
      var size = UInt32(MemoryLayout<CFString?>.size)
      let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<CFString?>.alignment,
      )
      defer { unsafe raw.deallocate() }
      let status = unsafe AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, raw)
      guard status == noErr else {
        throw RecordingError.systemAudioStartupFailure(status, operation: "read tap UID")
      }
      guard let uid = unsafe raw.assumingMemoryBound(to: CFString?.self).pointee as String? else {
        throw RecordingError.captureSourceFailed(
          sourceDescription: "systemAudio",
          details: "tap UID missing",
        )
      }
      return uid
    }

    private static func createAggregateDevice(
      input: SystemAudioRecordingInput,
      tapUID: String,
    ) throws(RecordingError) -> AudioObjectID {
      let uid = "\(input.aggregateDeviceUIDPrefix).\(UUID().uuidString)"
      let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: input.tapName,
        kAudioAggregateDeviceUIDKey: uid,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
      ]
      var aggregate = AudioObjectID(kAudioObjectUnknown)
      let status = unsafe AudioHardwareCreateAggregateDevice(
        description as CFDictionary,
        &aggregate,
      )
      guard status == noErr, aggregate != AudioObjectID(kAudioObjectUnknown) else {
        throw RecordingError.systemAudioStartupFailure(
          status,
          operation: "create aggregate device",
        )
      }
      return aggregate
    }

    private static func bufferFrameSize(deviceID: AudioObjectID) throws(RecordingError) -> Int {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyBufferFrameSize,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
      )
      var frames: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      let status = unsafe AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames)
      guard status == noErr, frames > 0 else {
        throw RecordingError.systemAudioStartupFailure(
          status,
          operation: "read aggregate buffer frame size",
        )
      }
      return Int(frames)
    }
  }

  /// `RecordingCaptureBackend` for system audio: a Core Audio process-tap session
  /// plus a non-realtime pump that drains the handoff and feeds the shared
  /// `processAudio` path via the injected sink.
  // SAFETY: pump state is an atomic; the reusable buffer is only touched on the
  // pump queue; the session is touched on start/stop/cleanup.
  @safe final class CoreAudioSystemAudioBackend: RecordingCaptureBackend, @unchecked Sendable {
    private let session: CoreAudioProcessTapSession
    private let sink: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    private let reusableBuffer: AVAudioPCMBuffer
    private let pumpQueue = DispatchQueue(label: "AIOEngine.systemAudio.pump", qos: .userInitiated)
    private let pumpRunning = ManagedAtomic<Bool>(false)

    init(
      session: CoreAudioProcessTapSession,
      sink: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
    ) throws(RecordingError) {
      self.session = session
      self.sink = sink
      guard let buffer = session.handoff.makeReusableBuffer(maxIOFrames: session.maxIOFrames) else {
        throw RecordingError.captureSourceFailed(
          sourceDescription: "systemAudio",
          details: "could not allocate source pump buffer",
        )
      }
      reusableBuffer = buffer
    }

    func start() throws(RecordingError) {
      try session.start()
      pumpRunning.store(true, ordering: .relaxed)
      let handoff = session.handoff
      // The reusable buffer is only ever touched on the pump queue; Transferring
      // moves it across the @Sendable closure boundary safely.
      let transferred = Transferring(reusableBuffer)
      let sink = self.sink
      let running = pumpRunning
      pumpQueue.async {
        let buffer = transferred.value
        log.info("📡 system-audio source pump started")
        while running.load(ordering: .relaxed) {
          var delivered = 0
          while running.load(ordering: .relaxed),
            handoff.drainOne(into: buffer, sink: sink) > 0
          {
            delivered += 1
          }
          if delivered == 0 {
            Thread.sleep(forTimeInterval: 0.002)
          }
        }
        log.info("📡 system-audio source pump stopped")
      }
    }

    @MainActor
    func stop(mode: RecordingCaptureStopMode) {
      pumpRunning.store(false, ordering: .relaxed)
      switch mode {
      case .graceful:
        do {
          try session.stop()
        } catch {
          log.error("system-audio stop failed: \(error, privacy: .public)")
        }
      case .immediate:
        session.cleanup()
      }
    }

    @MainActor
    func cleanup() {
      pumpRunning.store(false, ordering: .relaxed)
      session.cleanup()
    }
  }
#endif
