// © GoodHatsLLC

#if os(iOS)
  public import AIOContracts
  import AIOSupport
  public import AVFAudio
  import Foundation
  public import Observation
  import os
  public import Tools

  private let log = SystemLog.make()

  /// The audio-session authority and the sole public owner of microphone
  /// configuration request, capability, reconciliation, and applied state.
  @MainActor
  @Observable
  public final class AudioEnvironmentManager: AudioSessionAuthority {
    public enum ManagerError: AudioError {
      public enum AudioSessionOperation: String, Sendable, Equatable, CustomStringConvertible {
        case setCategory
        case setAllowHapticsAndSystemSoundsDuringRecording
        case setPrefersNoInterruptionsFromSystemAlerts
        case setPrefersInterruptionOnRouteDisconnect
        case setPreferredInputNumberOfChannels
        case setPreferredInputOrientation
        case setActive

        public var description: String { rawValue }
      }

      case alreadyRunning
      case notRunning
      case audioEnvironment(AudioEnvironment.RequestError)
      case audioInput(AudioInput.PreferenceError)
      case audioSource(AudioSource.PreferenceError)
      case audioSessionFailed(operation: AudioSessionOperation, error: ErrorContext)
      case inputConfigurationDeferred(AudioInputConfigurationDeferral)
      case inputConfigurationUnsatisfied(AudioInputConfigurationIssue)
      case unexpected(ErrorContext)

      public var description: String {
        switch self {
        case .alreadyRunning:
          "AudioEnvironmentManager is already running"
        case .notRunning:
          "AudioEnvironmentManager is not running"
        case .audioEnvironment(let error):
          "Audio environment error: \(error)"
        case .audioInput(let error):
          "Audio input error: \(error)"
        case .audioSource(let error):
          "Audio source error: \(error)"
        case .audioSessionFailed(let operation, let error):
          "Audio session operation '\(operation)' failed: \(error)"
        case .inputConfigurationDeferred(let deferral):
          "Input configuration is deferred: \(deferral)"
        case .inputConfigurationUnsatisfied(let issue):
          "Input configuration is unsatisfied: \(issue)"
        case .unexpected(let error):
          "Unexpected error: \(error)"
        }
      }
    }

    /// Prepares the shared category without activating the audio session.
    @MainActor
    public static func prepareAudioSessionCategoryForAppLaunch() {
      do {
        try configureAudioSessionCategory(
          AVAudioSession.sharedInstance(),
          configuration: .recordingConfiguration,
        )
      } catch {
        log.error(
          "Failed to prepare audio session category on launch: \(error.localizedDescription, privacy: .public)",
        )
      }
    }

    public nonisolated static func configureAudioSessionCategory(
      _ session: AVAudioSession,
      configuration: AudioSessionConfiguration,
    ) throws(ManagerError) {
      try AudioSessionAccess.result(catching: ManagerError.self) {
        () throws(ManagerError) -> Void in
        do {
          try session.setCategory(
            configuration.category,
            mode: configuration.mode,
            options: configuration.options,
          )
        } catch {
          throw .audioSessionFailed(operation: .setCategory, error: ErrorContext(error))
        }
        do {
          try session.setAllowHapticsAndSystemSoundsDuringRecording(
            configuration.allowsHapticsAndSystemSoundsDuringRecording,
          )
        } catch {
          throw .audioSessionFailed(
            operation: .setAllowHapticsAndSystemSoundsDuringRecording,
            error: ErrorContext(error),
          )
        }
        do {
          try session.setPrefersNoInterruptionsFromSystemAlerts(
            configuration.prefersNoInterruptionsFromSystemAlerts,
          )
        } catch {
          throw .audioSessionFailed(
            operation: .setPrefersNoInterruptionsFromSystemAlerts,
            error: ErrorContext(error),
          )
        }
        do {
          try session.setPrefersInterruptionOnRouteDisconnect(
            configuration.prefersInterruptionOnRouteDisconnect,
          )
        } catch {
          throw .audioSessionFailed(
            operation: .setPrefersInterruptionOnRouteDisconnect,
            error: ErrorContext(error),
          )
        }
      }.get()
    }

    public init(
      env: AudioEnvironment,
      errorManager: any ErrorManaging,
      defaults: UserDefaults = UserDefaults(),
    ) {
      let queue = SerialAsyncWorkQueue()
      let adapter = IOSAudioInputConfigurationAdapter(
        environment: env,
        inputWriteQueue: queue,
      )
      let coordinator = AudioInputConfigurationCoordinator(
        defaults: defaults,
        adapter: adapter,
      )
      self.env = env
      self.errorManager = errorManager
      inputWriteQueue = queue
      platformInputAdapter = adapter
      inputConfigurationCoordinator = coordinator
      inputConfigurationState = coordinator.state
      sessionConfiguration = .recordingConfiguration(
        useMeasurement: coordinator.state.requested.processing == .measurement,
      )
    }

    let env: AudioEnvironment
    let errorManager: any ErrorManaging
    @ObservationIgnored let inputWriteQueue: SerialAsyncWorkQueue
    @ObservationIgnored private let platformInputAdapter: IOSAudioInputConfigurationAdapter
    @ObservationIgnored private let inputConfigurationCoordinator:
      AudioInputConfigurationCoordinator
    @ObservationIgnored var callbackTasks = MainActorTaskRunner()

    private var lifecycleRuntime: AudioEnvironmentLifecycleRuntime { .init(owner: self) }
    var sessionBootstrap: AudioSessionBootstrap { .init(owner: self) }
    var sessionController: AudioSessionController { .init(owner: self) }
    var routeObserver: AudioRouteObserver { .init(owner: self) }

    public var sessionConfiguration: AudioSessionConfiguration
    public internal(set) var isRunning = false
    public internal(set) var isAudioSessionActive = false
    public internal(set) var isReady = false {
      didSet {
        if isReady {
          try? readinessSignal.yield()
        }
      }
    }
    public private(set) var inputConfigurationState: AudioInputConfigurationState

    public var recordingUsesMeasurementMode: Bool {
      let processing =
        inputConfigurationState.applied?.processing
        ?? inputConfigurationState.requested.processing
      return processing == .measurement
    }

    private let readinessSignal = AwaitableBox<Void>()
    private let eventHub = AudioEnvironmentEventHub()

    public var onRequestAudioSessionActive: (@MainActor (Bool) -> Void)?

    public var audioSessionActive: Bool {
      get { isAudioSessionActive }
      set {
        guard newValue != isAudioSessionActive else { return }
        if let handler = onRequestAudioSessionActive {
          handler(newValue)
        } else {
          callbackTasks.run { [weak self] in
            guard let self else { return }
            do {
              try await setAudioSessionActive(newValue)
            } catch {
              errorManager.enqueue(
                error,
                visibility: .userInterrupting,
                userMessage: newValue
                  ? "Couldn't enable the microphone."
                  : "Couldn't disable the microphone.",
                context: "Audio session",
              )
            }
          }
        }
      }
    }

    @discardableResult
    public func addAudioSystemEventSubscriber(
      _ handler: @escaping @Sendable @MainActor (AudioSystemEvent) async -> Void,
    ) -> UUID {
      eventHub.addSubscriber(handler)
    }

    public func removeSubscriber(_ id: UUID) {
      eventHub.removeSubscriber(id)
    }

    public func requestInputConfiguration(
      _ requested: AudioInputConfigurationRequest,
    ) async -> AudioInputConfigurationState {
      sessionConfiguration = .recordingConfiguration(
        useMeasurement: requested.processing == .measurement,
      )
      inputConfigurationState = await inputConfigurationCoordinator.submit(
        requested,
        isRunning: isRunning,
        isActive: isAudioSessionActive,
      )
      return inputConfigurationState
    }

    public func settleInputConfiguration() async throws(ManagerError)
      -> SettledMicrophoneInputConfiguration
    {
      try await readySignal()
      guard isAudioSessionActive else {
        throw .inputConfigurationDeferred(.sessionInactive)
      }
      await reconcileInputConfiguration()
      return try settledConfiguration(from: inputConfigurationState)
    }

    private func settledConfiguration(
      from state: AudioInputConfigurationState,
    ) throws(ManagerError) -> SettledMicrophoneInputConfiguration {
      switch state.reconciliation {
      case .satisfied:
        guard let applied = state.applied else {
          throw .inputConfigurationUnsatisfied(
            .readbackMismatch(
              expected: InputConfiguration(sampleRate: .dvd, channels: .mono),
              actual: nil,
            ),
          )
        }
        let preferredInput: AudioInputSelection? =
          switch state.requested.input {
          case .systemDefault: nil
          case .specific: applied.input
          }
        return SettledMicrophoneInputConfiguration(
          format: applied.format,
          preferredInput: preferredInput,
          source: applied.source,
          requestGeneration: state.requestedGeneration,
        )
      case .deferred(let deferral):
        throw .inputConfigurationDeferred(deferral)
      case .unsatisfied(let issue):
        throw .inputConfigurationUnsatisfied(issue)
      case .discovering, .reconciling:
        throw .inputConfigurationDeferred(.mediaServicesUnavailable)
      }
    }

    @MainActor
    func reconcileInputConfiguration(forcePlatformApply: Bool = false) async {
      inputConfigurationState = await inputConfigurationCoordinator.reconcile(
        isRunning: isRunning,
        isActive: isAudioSessionActive,
        forcePlatformApply: forcePlatformApply,
      )
    }

    @MainActor
    func markInputConfigurationUnavailable(
      _ deferral: AudioInputConfigurationDeferral,
    ) {
      inputConfigurationState = inputConfigurationCoordinator.markUnavailable(deferral)
    }

    @MainActor
    func updateOrientation(
      _ orientation: AVAudioSession.StereoOrientation,
    ) async {
      await platformInputAdapter.updateOrientation(orientation)
      if isAudioSessionActive {
        await reconcileInputConfiguration(forcePlatformApply: true)
      }
    }

    @MainActor
    public func readySignal() async throws(ManagerError) {
      guard isRunning else {
        assert(!isReady)
        throw .notRunning
      }
      await readinessSignal()
      assert(isReady)
    }

    public func setAudioSessionActive(_ active: Bool) async throws(ManagerError) {
      try await sessionController.setAudioSessionActive(active)
    }

    public func run() async throws(ManagerError) {
      try await lifecycleRuntime.run(sessionConfiguration: sessionConfiguration)
    }

    @MainActor
    func dispatchAudioSystemEvent(_ event: AudioSystemEvent) async {
      await eventHub.dispatch(event)
    }
  }
#endif
