// © GoodHatsLLC

#if canImport(AVFoundation)
  // These protocols are `public` and their requirements are spelled in types
  // from these modules, so the imports must be public too. They were internal
  // while AIORecording `@_exported`-ed the same modules, which made the types
  // reachable without saying so here.
  public import AIOAudioSession
  public import AIOContracts
  public import AIOEngineCore
  import Foundation
  public import Observation
  public import Tools

  public typealias AudioEnvironmentError = AudioEnvironmentManager.ManagerError

  @MainActor
  public protocol AudioEnvironmentEventSubscribing: AnyObject, Sendable {
    @discardableResult
    func addAudioSystemEventSubscriber(
      _ handler: @escaping @Sendable @MainActor (AudioSystemEvent) async -> Void,
    ) -> UUID

    func removeSubscriber(_ id: UUID)
  }

  @MainActor
  public protocol AudioEnvironmentDriving: AnyObject, Sendable {
    var isAudioSessionActive: Bool { get }

    /// The contract the next microphone capture starts with, derived from the
    /// request against the live environment. Never refuses; see
    /// ``CaptureInputContract``.
    func resolveCaptureInputContract()
      async throws(AudioEnvironmentError) -> CaptureInputContract
    /// Keeps the session engaged until the returned hold is released, so a
    /// configuration surface shows the route the next recording runs on.
    func acquireAudioSessionHold() async throws(AudioEnvironmentError) -> AudioSessionHold
    func setAudioSessionActive(_ active: Bool) async throws(AudioEnvironmentError)

    func readySignal() async throws(AudioEnvironmentError)
    func run() async throws(AudioEnvironmentError)
  }

  @MainActor
  public protocol AudioEnvironmentConfiguring: AudioEnvironmentDriving, Observable {
    var inputConfigurationState: AudioInputConfigurationState { get }

    func requestInputConfiguration(
      _ requested: AudioInputConfigurationRequest
    ) async -> AudioInputConfigurationState

    /// Re-reads capabilities and applied state from the platform without
    /// changing the request.
    func refreshInputConfiguration() async -> AudioInputConfigurationState
  }

  @MainActor
  public protocol OutputConfigurationProviding: AnyObject {
    var outputConfiguration: OutputConfiguration? { get }
  }

  public protocol RecordingDriving: Sendable {
    @MainActor var isRecording: Bool { get }
    var events: AsyncBroadcaster<AudioIOEvent> { get }

    /// Canonical awaited recording start. Transient readiness is reconciled by
    /// the engine and every failure is returned as a typed throw.
    @MainActor
    func startRecording(
      configuration: RecordingConfiguration,
    ) async throws(RecordingError) -> URL

    /// Stops capture and reports the final file with the persisted-frame
    /// position at which it ends — the capture's total frame count.
    @MainActor func stopRecording() async throws(RecordingError) -> RecordingCompletion

    /// Continues capture into a new file and reports the completed file with
    /// the persisted-frame position at which it ends and the next begins.
    @MainActor func rotateRecordingFile() async throws(RecordingError) -> RecordingRotation

    /// The host-time interval and exact persisted frame counts of the current recording, for
    /// multi-device alignment and effective sample-rate measurement.
    /// Returns `nil` if no persisted buffer with a valid host time has been captured since the last
    /// recording start. The value persists after ``stopRecording()`` until the next start, so read
    /// it immediately after stopping for a complete snapshot. Defaults to `nil` for conformers that
    /// do not surface capture timing.
    ///
    /// The counts are cumulative for the whole capture and do **not** reset at a rotation. For
    /// per-file frame positions use the boundaries returned by ``rotateRecordingFile()`` and
    /// ``stopRecording()``, which are sampled where the split is decided rather than read back
    /// afterwards.
    @MainActor func recordingTimingSnapshot() -> RecordingTimingSnapshot?

    @discardableResult
    func attachBufferReceiver(_ receiver: some BufferReceiver<Float>) async -> BufferReceiverToken
    func detachBufferReceivers() async

    @MainActor func updateRecordingTapInterval(_ interval: Duration)
  }

  extension RecordingDriving {
    @MainActor
    public func recordingTimingSnapshot() -> RecordingTimingSnapshot? {
      nil
    }
  }

  extension AIOEngine: RecordingDriving {}
  extension AudioEnvironmentManager: AudioEnvironmentEventSubscribing {}
  extension AudioEnvironmentManager: AudioEnvironmentDriving {}
  extension AudioEnvironmentManager: AudioEnvironmentConfiguring {}
  extension OutputConfigurationManager: OutputConfigurationProviding {}

#endif
