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

  #if os(iOS)
    public import AVFAudio
  #endif

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
    var inputHasStereoSource: Bool { get }
    var isConfiguredForStereo: Bool { get }
    var shouldAutoSelectStereoWhenAvailable: Bool { get }

    var isAudioSessionActive: Bool { get }
    var sampleRate: SampleRate { get }
    var channels: ChannelCount { get }

    func applyStereo() async throws(AudioEnvironmentError)
    func setAudioSessionActive(_ active: Bool) async throws(AudioEnvironmentError)

    func readySignal() async throws(AudioEnvironmentError)
    func run() async throws(AudioEnvironmentError)
  }

  @MainActor
  public protocol AudioEnvironmentConfiguring: AudioEnvironmentDriving, Observable {
    var audioSessionActive: Bool { get set }
    var sampleRate: SampleRate { get set }
    var selectedInput: AudioInput? { get set }
    var selectedSource: AudioSource? { get set }
    var useMeasurement: Bool { get set }

    var availableInputs: [AudioInput] { get }
    var availableSources: [AudioSource] { get }
    var availableChannelCountsForSelectedSource: [ChannelCount] { get }
    var channelConfigurationAvailability: AudioChannelConfigurationAvailability { get }
    var likelySupportedSampleRates: [SampleRate] { get }

    func applyMono() async throws(AudioEnvironmentError)
    func applySourceConfiguration(
      source: AudioSource,
      channelCount: ChannelCount,
      polarPattern: PolarPattern?,
      persistPreference: Bool,
    ) async throws(AudioEnvironmentError)
  }

  #if os(iOS)
    @MainActor
    public protocol AudioInputPickingEnvironment: AudioEnvironmentConfiguring {
      var session: AVAudioSession { get }
    }
  #else
    // On macOS the AVAudioSession-bound input picker doesn't exist. Aliasing
    // to `AudioEnvironmentConfiguring` lets cross-platform views (e.g.
    // `ConfigurationView`, `RecordingSheetView`) constrain their generic on
    // `AudioInputPickingEnvironment` uniformly; the iOS-only call sites that
    // need the stricter `session: AVAudioSession` member are themselves
    // guarded by `#if os(iOS)`.
    public typealias AudioInputPickingEnvironment = AudioEnvironmentConfiguring
  #endif

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

    @MainActor func stopRecording() async throws(RecordingError) -> URL
    @MainActor func rotateRecordingFile() async throws(RecordingError) -> URL

    /// The host-time interval and exact persisted frame counts of the current (or just-finished)
    /// recording segment, for multi-device alignment and effective sample-rate measurement.
    /// Returns `nil` if no persisted buffer with a valid host time has been captured since the last
    /// recording start. The value persists after ``stopRecording()`` until the next start, so read
    /// it immediately after stopping for a complete snapshot. Defaults to `nil` for conformers that
    /// do not surface capture timing.
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
  #if os(iOS)
    extension AudioEnvironmentManager: AudioInputPickingEnvironment {}
  #endif
  extension OutputConfigurationManager: OutputConfigurationProviding {}

#endif
