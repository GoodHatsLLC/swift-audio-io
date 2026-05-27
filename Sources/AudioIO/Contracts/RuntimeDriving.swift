// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOContracts
  import AIOEngineCore
  import AIORecording
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

    @MainActor
    func setDesiredRecordingState(
      _ desiredState: Bool,
      configuration: RecordingConfiguration?,
    )

    @MainActor
    func startRecordingWithReconciliation(
      configuration: RecordingConfiguration,
    ) async -> Bool

    @MainActor func consumeLastRecordingStartFailure() -> AIOEngine.AIOError?

    @MainActor func stopRecording() async throws(AIOEngine.AIOError) -> URL
    @MainActor func rotateRecordingFile() async throws(AIOEngine.AIOError) -> URL

    @discardableResult
    func attachBufferReceiver(_ receiver: some BufferReceiver<Float>) async -> BufferReceiverToken
    func detachBufferReceivers() async

    @MainActor func updateRecordingTapInterval(_ interval: Duration)
  }

  extension RecordingDriving {
    @MainActor
    public func setDesiredRecordingState(_ desiredState: Bool) {
      setDesiredRecordingState(desiredState, configuration: nil)
    }

    @MainActor
    public func consumeLastRecordingStartFailure() -> AIOEngine.AIOError? {
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
