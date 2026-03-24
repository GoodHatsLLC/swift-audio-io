// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession
  import AIOContracts
  import AIOEngineCore
  import AIORecording
  import Foundation
  import Tools

  @MainActor
  public protocol AudioEnvironmentDriving: AnyObject, Sendable {
    var inputHasStereoSource: Bool { get }
    var isConfiguredForStereo: Bool { get }
    var shouldAutoSelectStereoWhenAvailable: Bool { get }

    var isAudioSessionActive: Bool { get }
    var sampleRate: SampleRate { get }
    var channels: ChannelCount { get }

    func applyStereo() async throws(AudioEnvironmentManager.ManagerError)
    func setAudioSessionActive(_ active: Bool) throws(AudioEnvironmentManager.ManagerError)

    func readySignal() async throws(AudioEnvironmentManager.ManagerError)
    func run() async throws(AudioEnvironmentManager.ManagerError)
  }

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

    func attachBufferReceiver(_ receiver: some BufferReceiver<Float>) async
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
  extension AudioEnvironmentManager: AudioEnvironmentDriving {}
  extension OutputConfigurationManager: OutputConfigurationProviding {}

#endif
