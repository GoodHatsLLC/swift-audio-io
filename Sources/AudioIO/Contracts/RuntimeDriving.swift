// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOContracts
  import AIOEngineCore
  @_spi(Advanced) import AIORecording
  import Foundation
  public import Observation
  import Tools

  #if os(iOS)
    public import AVFAudio
  #endif

  public typealias AudioEnvironmentError = AudioEnvironmentManager.ManagerError

  @MainActor
  public protocol AudioEnvironmentEventSubscribing: AnyObject, Sendable {
    @discardableResult
    func addRouteChangeSubscriber(
      _ handler: @escaping @Sendable @MainActor (AudioRouteChangeEvent) async -> Void,
    ) -> UUID

    @discardableResult
    func addInterruptionSubscriber(
      _ handler:
        @escaping @Sendable @MainActor (AudioInterruptionType, AudioInterruptionOptions?)
        async -> Void,
    ) -> UUID

    @discardableResult
    func addMediaServicesLostSubscriber(
      _ handler: @escaping @Sendable @MainActor () async -> Void,
    ) -> UUID

    @discardableResult
    func addMediaServicesResetSubscriber(
      _ handler: @escaping @Sendable @MainActor () async -> Void,
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
    func setAudioSessionActive(_ active: Bool) throws(AudioEnvironmentError)

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
    @MainActor var wantsRecording: Bool { get }
    @MainActor var isRecording: Bool { get }
    var errors: AsyncBroadcaster<any Error> { get }

    /// Reconciliation-mode start primitive. See
    /// ``AIOEngine/setDesiredRecordingState(_:configuration:)`` for semantics.
    /// Marked `@_spi(Advanced)` because the canonical entry point is
    /// ``AIOEngine/startRecording(configuration:)``; consumers that need the
    /// retry-until-warm state machine should opt in explicitly with
    /// `@_spi(Advanced) import AudioIO`.
    @_spi(Advanced)
    @MainActor
    func setDesiredRecordingState(
      _ desiredState: Bool,
      configuration: RecordingConfiguration?,
    )

    /// Awaitable form of ``setDesiredRecordingState(_:configuration:)``. See
    /// ``AIOEngine/startRecordingWithReconciliation(configuration:)``.
    @_spi(Advanced)
    @MainActor
    func startRecordingWithReconciliation(
      configuration: RecordingConfiguration,
    ) async -> Bool

    /// The most recent failure observed by the reconciliation task while
    /// trying to start recording. Cleared on read. Surfaces failures that
    /// the fire-and-forget ``setDesiredRecordingState(_:configuration:)``
    /// can't return directly.
    @_spi(Advanced)
    @MainActor func consumeLastRecordingStartFailure() -> RecordingError?

    @MainActor func stopRecording() async throws(RecordingError) -> URL
    @MainActor func rotateRecordingFile() async throws(RecordingError) -> URL

    @discardableResult
    func attachBufferReceiver(_ receiver: some BufferReceiver<Float>) async -> BufferReceiverToken
    func detachBufferReceivers() async

    @MainActor func updateRecordingTapInterval(_ interval: Duration)
  }

  extension RecordingDriving {
    @_spi(Advanced)
    @MainActor
    public func setDesiredRecordingState(_ desiredState: Bool) {
      setDesiredRecordingState(desiredState, configuration: nil)
    }

    @_spi(Advanced)
    @MainActor
    public func consumeLastRecordingStartFailure() -> RecordingError? {
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
