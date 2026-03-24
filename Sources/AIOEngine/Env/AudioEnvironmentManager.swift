// © GoodHatsLLC

#if os(iOS)
  public import AVFAudio
  import Combine
  import Foundation
  public import Observation
  import os
  public import Tools

  private let log = SystemLog.make()

  /// Manages the audio environment, including the audio session, input and output devices, and sample rate.
  ///
  /// This class is responsible for:
  /// - Configuring and managing the `AVAudioSession`.
  /// - Handling audio session interruptions and route changes.
  /// - Providing information about the available audio inputs and sources.
  /// - Allowing the user to select the preferred input, source, and sample rate.
  @MainActor
  @Observable
  public final class AudioEnvironmentManager: AudioSessionDelegate {
    public enum ManagerError: AudioError {
      public enum AudioSessionOperation: String, Sendable, Equatable, CustomStringConvertible {
        case setCategory
        case setAllowHapticsAndSystemSoundsDuringRecording
        case setPrefersNoInterruptionsFromSystemAlerts
        case setPrefersInterruptionOnRouteDisconnect
        case setPreferredInputNumberOfChannels
        case setPreferredInputOrientation
        case setActive

        public var description: String {
          rawValue
        }
      }

      case alreadyRunning
      case notRunning
      case audioEnvironment(AudioEnvironment.RequestError)
      case audioInput(AudioInput.PreferenceError)
      case audioSource(AudioSource.PreferenceError)
      case audioSessionFailed(operation: AudioSessionOperation, error: ErrorContext)
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
        case .unexpected(let error):
          "Unexpected error: \(error)"
        }
      }
    }

    /// Prepares the shared audio session category/options as early as possible on app launch.
    ///
    /// This intentionally does **not** activate the audio session; activation should only occur when
    /// the app has expressed an intent to capture or play audio.
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

    /// Configures the audio session category/options, but does not activate the session.
    ///
    /// Activation (`setActive(true)`) is intentionally separated so the app can avoid claiming the
    /// microphone/audio session until explicitly requested.
    public nonisolated static func configureAudioSessionCategory(
      _ session: AVAudioSession,
      configuration: AudioSessionConfiguration,
    ) throws(ManagerError) {
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
    }

    /// Creates a new `AudioEnvironmentManager` instance.
    ///
    /// - Parameters:
    ///   - env: The audio environment to use.
    ///   - errorManager: The error manager to use for reporting errors.
    public init(
      env: AudioEnvironment,
      errorManager: any ErrorManaging,
      defaults: UserDefaults = .standard,
    ) {
      let preferenceStore = AudioEnvironmentPreferenceStore(defaults: defaults)
      self.env = env
      self.errorManager = errorManager
      self.preferenceStore = preferenceStore
      _input = env.input
      _availableInputs = env.availableInputs
      _selectedSource = env.input?.selectedSource
      _selectedSampleRate = env.sampleRate
      _availableSources = env.input?.availableSources ?? []
      _orientation = .none
      _selectedNumberOfChannels = (env.input?.channelCount) ?? .mono
      _useMeasurement = preferenceStore.useMeasurement
    }

    private let env: AudioEnvironment
    /// The underlying `AVAudioSession`.
    public var session: AVAudioSession {
      env.session
    }

    /// The preferred category/mode/options for this environment.
    public var sessionConfiguration: AudioSessionConfiguration = .recordingConfiguration
    private let errorManager: any ErrorManaging
    private let preferenceStore: AudioEnvironmentPreferenceStore
    private typealias PersistedInputPreferences = AudioEnvironmentPreferenceStore.InputPreferences
    private var sessionBootstrap: AudioSessionBootstrap { .init(owner: self) }
    private var sessionController: AudioSessionController { .init(owner: self) }
    private var inputPreferenceController: AudioInputPreferenceController { .init(owner: self) }
    private var inputPreferenceRestorer: AudioInputPreferenceRestorer { .init(owner: self) }
    private var routeObserver: AudioRouteObserver { .init(owner: self) }

    /// Describes audio input configuration operations that require synchronous XPC
    /// round-trips to `mediaserverd`. Computed on MainActor (where cached state is
    /// readable) then executed off MainActor via ``executeInputConfiguration(_:session:)``
    /// to avoid run-loop hangs.
    private struct InputConfigurationPlan {
      var channelCount: Int?
      var polarPatternSource: AudioSource?
      var polarPattern: PolarPattern?
      var preferredInput: AudioInput?
      var preferredSource: AudioSource?
      var inputOrientation: AVAudioSession.StereoOrientation?
    }

    /// Error wrapper that preserves the origin of failures inside
    /// ``executeInputConfiguration(_:session:)`` so they can be mapped back
    /// to the correct ``ManagerError`` case.
    private enum _InputConfigError: Error {
      case channelCount(ErrorContext)
      case polarPattern(AudioSource.PreferenceError)
      case preferredSource(AudioInput.PreferenceError)
      case inputOrientation(ErrorContext)
      case unexpected(ErrorContext)
    }

    /// Executes XPC-blocking AVAudioSession preference calls off the main actor.
    ///
    /// These calls (`setPreferredPolarPattern`, `setPreferredDataSource`, etc.) make
    /// synchronous XPC round-trips to `mediaserverd` that can each block for 100–500 ms.
    /// Running them off the main actor prevents UIKit run-loop hangs.
    ///
    /// - Note: `setCategory` and `setActive` intentionally remain on MainActor per Apple
    ///   DTS guidance. Only input-preference calls are moved here.
    private nonisolated static func executeInputConfiguration(
      _ plan: InputConfigurationPlan,
      session: AVAudioSession,
    ) async throws(ManagerError) {
      let t = Task.detached {
        if let count = plan.channelCount {
          do {
            try session.setPreferredInputNumberOfChannels(count)
          } catch {
            return Result<Void, ManagerError>.failure(
              .audioSessionFailed(
                operation: .setPreferredInputNumberOfChannels, error: ErrorContext(error),
              ),
            )
          }
        }

        if let source = plan.polarPatternSource, let pattern = plan.polarPattern {
          do {
            try source.set(preferredPolarPattern: pattern)
          } catch let err as AudioSource.PreferenceError {
            return Result<Void, ManagerError>.failure(.audioSource(err))
          }
        }

        if let input = plan.preferredInput, let source = plan.preferredSource {
          do {
            try input.set(preferredSource: source)
          } catch let error as AudioInput.PreferenceError {
            return Result<Void, ManagerError>.failure(.audioInput(error))
          }
        }

        if let orientation = plan.inputOrientation {
          do {
            try session.setPreferredInputOrientation(orientation)
          } catch {
            return Result<Void, ManagerError>.failure(
              .audioSessionFailed(operation: .setPreferredInputOrientation, error: .init(error)),
            )
          }
        }
        return .success(())
      }
      do {
        let result = try await t.value
        switch result {
        case .success: return
        case .failure(let managerError): throw managerError
        }
      } catch {
        throw ManagerError.unexpected(ErrorContext(error))
      }
    }

    private var isRestoringFromDefaults: Bool = false

    public var shouldAutoSelectStereoWhenAvailable: Bool {
      let inputId = env.input?.id ?? "_default"
      return !preferenceStore.hasPreferences(for: inputId)
    }

    public var useMeasurement: Bool = AudioSessionConfiguration.useMeasurement {
      willSet {
        if AudioSessionConfiguration.useMeasurement != newValue {
          AudioSessionConfiguration.useMeasurement = newValue
        }
      }
    }

    /// A Boolean value that indicates whether this `AudioEnvironmentManager` is fully primed and subscribed.
    public private(set) var isReady: Bool = false {
      didSet {
        if isReady {
          try? readinessSignal.yield()
        }
      }
    }

    private let readinessSignal = AwaitableBox<Void>()
    /// If the `AudioEnvironmentManager` is running, suspends until `isReady` is `true`.
    ///
    /// - Important: This call throws if the `AudioEnvironmentManager` has not been started with `run()`.
    @MainActor public func readySignal() async throws(ManagerError) {
      if !isRunning {
        assert(!isReady)
        throw .notRunning
      }
      await readinessSignal()
      assert(isReady)
    }

    /// A handler invoked when UI requests a change to the audio session active state.
    ///
    /// Set this to route activation/deactivation through the appropriate service
    /// (e.g. `RecordingService`) that can ensure the audio environment is running first.
    public var onRequestAudioSessionActive: (@MainActor (Bool) -> Void)?

    /// Bindable audio session active state.
    ///
    /// The getter returns the actual session state. The setter invokes
    /// ``onRequestAudioSessionActive`` to request a state change; the actual state
    /// reconciles once the request completes (or remains unchanged on failure).
    public var audioSessionActive: Bool {
      get { isAudioSessionActive }
      set {
        guard newValue != isAudioSessionActive else { return }
        if let handler = onRequestAudioSessionActive {
          handler(newValue)
        } else {
          do {
            try setAudioSessionActive(newValue)
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

    /// A callback that is invoked when the audio route changes.
    public var onRouteChange: (@Sendable @MainActor (AudioRouteChangeEvent) async -> Void)?

    /// A callback that is invoked when an audio interruption occurs.
    public var onInterruption:
      (
        @Sendable @MainActor (AVAudioSession.InterruptionType, AVAudioSession.InterruptionOptions?)
          async -> Void
      )?

    /// A callback that is invoked when media services are lost.
    public var onMediaServicesLost: (@Sendable @MainActor () async -> Void)?

    /// A callback that is invoked when media services are reset.
    public var onMediaServicesReset: (@Sendable @MainActor () async -> Void)?

    private let eventHub = AudioEnvironmentEventHub()

    /// A Boolean value that indicates whether the manager is currently running.
    public private(set) var isRunning: Bool = false

    /// A Boolean value that indicates whether the audio session is currently active.
    public private(set) var isAudioSessionActive: Bool = false
    private var _orientation: AVAudioSession.StereoOrientation
    private var _selectedNumberOfChannels: ChannelCount
    private var _input: AudioInput?
    private var _selectedSource: AudioSource?
    private var _selectedSampleRate: SampleRate
    private var _availableInputs: [AudioInput]
    private var _availableSources: [AudioSource]
    private var state: AudioEnvironmentState {
      get {
        AudioEnvironmentState(
          input: _input,
          selectedSource: _selectedSource,
          selectedSampleRate: _selectedSampleRate,
          availableInputs: _availableInputs,
          availableSources: _availableSources,
          selectedNumberOfChannels: _selectedNumberOfChannels,
        )
      }
      set {
        _input = newValue.input
        _selectedSource = newValue.selectedSource
        _selectedSampleRate = newValue.selectedSampleRate
        _availableInputs = newValue.availableInputs
        _availableSources = newValue.availableSources
        _selectedNumberOfChannels = newValue.selectedNumberOfChannels
      }
    }

    @discardableResult
    public func addRouteChangeSubscriber(
      _ handler: @escaping @Sendable @MainActor (AudioRouteChangeEvent) async -> Void,
    ) -> UUID {
      eventHub.addRouteChangeSubscriber(handler)
    }

    @discardableResult
    public func addInterruptionSubscriber(
      _ handler:
        @escaping @Sendable @MainActor (AudioInterruptionType, AudioInterruptionOptions?)
        async -> Void,
    ) -> UUID {
      eventHub.addInterruptionSubscriber(handler)
    }

    @discardableResult
    public func addMediaServicesLostSubscriber(
      _ handler: @escaping @Sendable @MainActor () async -> Void,
    ) -> UUID {
      eventHub.addMediaServicesLostSubscriber(handler)
    }

    @discardableResult
    public func addMediaServicesResetSubscriber(
      _ handler: @escaping @Sendable @MainActor () async -> Void,
    ) -> UUID {
      eventHub.addMediaServicesResetSubscriber(handler)
    }

    public func removeSubscriber(_ id: UUID) {
      eventHub.removeSubscriber(id)
    }

    /// The current orientation of the device.
    public var orientation: AVAudioSession.StereoOrientation {
      _orientation
    }

    /// The number of channels for the current input.
    public var channels: ChannelCount {
      _selectedNumberOfChannels
    }

    /// The available audio sources for the current input.
    public var availableSources: [AudioSource] {
      _availableSources
    }

    /// The available audio inputs.
    public var availableInputs: [AudioInput] {
      _availableInputs
    }

    /// The common sample rates.
    public var commonSampleRates: [SampleRate] {
      SampleRate.commonCases
    }

    /// The sample rates likely to be honored for the currently selected input.
    ///
    /// This list starts from common rates and removes rates previously rejected by
    /// the active route. The currently active sample rate is always included.
    public var likelySupportedSampleRates: [SampleRate] {
      [
        commonSampleRates
          + [env.sampleRate]
          + [_selectedSampleRate]
      ].flatMap(\.self)
        .removingDuplicates()
        .sorted()
    }

    /// The current sample rate.
    public var sampleRate: SampleRate {
      get {
        _selectedSampleRate
      }
      set {
        setSampleRate(newValue, persistPreference: true)
      }
    }

    public func setSampleRate(_ newValue: SampleRate, persistPreference: Bool) {
      errorManager.report {
        try env.request(sampleRate: newValue)
        _selectedSampleRate = newValue
        Task { @MainActor in
          let actual = env.sampleRate
          if actual == newValue {
            log.info("􁐚 Sample rate set to requested value: \(newValue, privacy: .public)")

          } else {
            log
              .info(
                """
                􁐚 Sample rate \(newValue, privacy: .public) rejected. \
                Set to \(actual, privacy: .public)
                """,
              )
            if persistPreference {
              persistInputPreferencesIfNeeded { prefs in
                var rejected = Set(prefs.rejectedSampleRatesHz ?? [])
                rejected.insert(newValue.rawValue)
                rejected.remove(actual.rawValue)
                prefs.rejectedSampleRatesHz = rejected.sorted()
              }
            }
            _selectedSampleRate = actual
          }
          if persistPreference {
            persistInputPreferencesIfNeeded { prefs in
              prefs.sampleRateHz = actual.rawValue
            }
          }
        }
      } catch: { error in
        let actual = env.sampleRate
        _selectedSampleRate = env.sampleRate
        log
          .error(
            """
            􁐚 Sample rate \(newValue, privacy: .public) failed with: \(error, privacy: .public) \
            Rate is \(actual, privacy: .public).
            """,
          )
        if persistPreference {
          // Persist the actual device rate on failure so we don't repeatedly retry
          // an unsupported preference for this input across route changes.
          persistInputPreferencesIfNeeded { prefs in
            prefs.sampleRateHz = actual.rawValue
            var rejected = Set(prefs.rejectedSampleRatesHz ?? [])
            rejected.insert(newValue.rawValue)
            rejected.remove(actual.rawValue)
            prefs.rejectedSampleRatesHz = rejected.sorted()
          }
        }
      }
    }

    /// The currently selected audio input.
    public var selectedInput: AudioInput? {
      get {
        _input ?? env.input ?? env.availableInputs.first
      }
      set {
        do {
          try env.request(input: newValue)
          _input = env.input
          _selectedSampleRate = env.sampleRate
          _selectedNumberOfChannels = (env.input?.channelCount) ?? .mono
          _availableInputs = env.availableInputs
          let validSources = env.input?.availableSources ?? []
          _availableSources = validSources
          let currentSource = env.source
          if let currentSource, validSources.contains(currentSource) {
            _selectedSource = currentSource
          } else {
            _selectedSource = nil
            do {
              if let fallback = validSources.first {
                try env.request(source: fallback)
                _selectedSource = env.source
              } else {
                try env.request(source: nil)
              }
            } catch {
              errorManager.enqueue(error)
            }
          }
          _availableSources = env.input?.availableSources ?? validSources
          persistInputPreferencesIfNeeded { prefs in
            prefs.sampleRateHz = env.sampleRate.rawValue
            prefs.channelCount = _selectedNumberOfChannels.count
            prefs.sourceId = env.source?.id
          }
        } catch {
          errorManager.enqueue(error)
        }
      }
    }

    /// The currently selected audio source.
    public var selectedSource: AudioSource? {
      get {
        _selectedSource
      }
      set {
        if let newValue, !_availableSources.contains(newValue) {
          _selectedSource = env.source
          return
        }
        do {
          try env.request(source: newValue)
          _input = env.input
          _selectedSampleRate = env.sampleRate
          _selectedNumberOfChannels = (env.input?.channelCount) ?? .mono
          _availableInputs = env.availableInputs
          _selectedSource = env.source
          _availableSources = env.availableSources
          persistInputPreferencesIfNeeded { prefs in
            prefs.sourceId = env.source?.id
          }
        } catch {
          _input = env.input
          _selectedSampleRate = env.sampleRate
          _selectedNumberOfChannels = (env.input?.channelCount) ?? .mono
          _availableInputs = env.availableInputs
          _selectedSource = env.source
          _availableSources = env.input?.availableSources ?? []
          errorManager.enqueue(error)
          persistInputPreferencesIfNeeded { prefs in
            prefs.sourceId = env.source?.id
          }
        }
      }
    }

    // TODO: since this is inherently dynamic it's not clear it should be input configuration.
    /// The current input configuration.
    public var inputConfiguration: InputConfiguration? {
      guard isReady else {
        return nil
      }

      let sampleRate = session.sampleRate
      guard sampleRate > 0 else {
        return nil
      }

      let sessionChannels = session.inputNumberOfChannels
      let resolvedChannels: ChannelCount =
        if sessionChannels > 0 {
          .init(platform: AVAudioChannelCount(sessionChannels))
        } else {
          _selectedNumberOfChannels
        }

      return .init(
        sampleRate: .init(rawValue: sampleRate),
        channels: resolvedChannels,
      )
    }

    /// A Boolean value that indicates whether the current input has a stereo source.
    public var inputHasStereoSource: Bool {
      let allDataSources: [AudioSource] = (env.input?.availableSources ?? [])
      let stereoSources = allDataSources.filter {
        $0.supportedPolarPatterns.contains(.stereo)
      }
      return !stereoSources.isEmpty
    }

    /// Returns the valid channel counts for the currently selected audio source.
    ///
    /// This is used to filter the channel count options shown in the UI.
    public var availableChannelCountsForSelectedSource: [ChannelCount] {
      guard let selectedSource = _selectedSource else {
        // No source selected - return both options if input has stereo capability
        return inputHasStereoSource ? [.mono, .stereo] : [.mono]
      }

      let patterns = selectedSource.supportedPolarPatterns

      // If no patterns are specified, assume the source is compatible with any mode
      guard !patterns.isEmpty else {
        return [.mono, .stereo]
      }

      let supportsStereo = patterns.contains(.stereo)
      let supportsNonStereo = patterns.contains(where: { $0 != .stereo })

      switch (supportsStereo, supportsNonStereo) {
      case (true, true):
        // Source supports both stereo and non-stereo patterns
        return [.mono, .stereo]
      case (true, false):
        // Source only supports stereo pattern
        return [.stereo]
      case (false, true), (false, false):
        // Source only supports non-stereo patterns (or no patterns, handled above)
        return [.mono]
      }
    }

    /// A Boolean value that indicates whether the audio session is configured for stereo.
    public var isConfiguredForStereo: Bool {
      session.inputNumberOfChannels > 1
    }

    /// Applies a mono audio configuration.
    ///
    /// This method forces the audio session to use a single input channel and attempts to select a non-stereo polar pattern if available.
    ///
    /// - Throws: An error if the audio session cannot be configured for mono.
    public func applyMono() async throws(ManagerError) {
      try await applyMono(persistPreference: true)
    }

    public func applyMono(persistPreference: Bool) async throws(ManagerError) {
      try await applyMonoInternal(persistPreference: persistPreference)
    }

    private func applyMonoInternal(persistPreference: Bool) async throws(ManagerError) {
      try await inputPreferenceController.applyMono(persistPreference: persistPreference)
    }

    /// Applies a stereo audio configuration.
    ///
    /// This method attempts to select a stereo-capable audio source and polar pattern. If it fails, it falls back to a mono configuration.
    ///
    /// - Throws: An error if the audio session cannot be configured for stereo.
    public func applyStereo() async throws(ManagerError) {
      try await applyStereo(persistPreference: true)
    }

    public func applyStereo(persistPreference: Bool) async throws(ManagerError) {
      try await applyStereoInternal(persistPreference: persistPreference)
    }

    private func applyStereoInternal(persistPreference: Bool) async throws(ManagerError) {
      try await inputPreferenceController.applyStereo(persistPreference: persistPreference)
    }

    /// Manually sets the audio session active state.
    ///
    /// This allows enabling or disabling the audio session independently of recording.
    /// When active, the app claims the audio session and can receive audio input.
    ///
    /// - Parameter active: Whether the audio session should be active.
    /// - Throws: An error if the audio session state cannot be changed.
    public func setAudioSessionActive(_ active: Bool) throws(ManagerError) {
      try sessionController.setAudioSessionActive(active)
    }
  }

  extension AudioEnvironmentManager {
    @MainActor
    private func subscribeToOrientation(
      _ onChange: @MainActor (AVAudioSession.StereoOrientation) -> Void,
    ) async {
      let deviceInfo = PlatformDevice.create()

      // Set initial orientation
      let initial = await deviceInfo.currentOrientation
      onChange(initial.avAudioSessionOrientation)

      // Subscribe to changes
      for await orientation in deviceInfo.orientationChanges() {
        onChange(orientation.avAudioSessionOrientation)
      }
    }

    /// Runs the audio environment manager.
    ///
    /// This method starts the audio session and begins monitoring for notifications such as route changes and interruptions.
    /// It will suspend without returning until its task is cancelled. On cancellation, it performs teardown and returns.
    ///
    /// - Throws: An error if the manager is already running.
    public func run() async throws(ManagerError) {
      guard !isRunning else {
        throw .alreadyRunning
      }
      log.info("🔊 AudioEnvironmentManager.run() started")

      isRunning = true
      defer { isRunning = false }

      // Wait for session configuration to complete before starting notifications.
      var isConfigured = false
      var configureAttempt = 0
      var configureRetryDelay: Duration = .milliseconds(100)
      let maxConfigureRetryDelay: Duration = .seconds(2)
      while !isConfigured {
        configureAttempt += 1
        do {
          try await sessionBootstrap.configureInitialSession(configuration: sessionConfiguration)
          isConfigured = true
        } catch {
          if Task.isCancelled {
            return
          }

          log.error(
            """
            Engine failed to configure audio session (attempt \(configureAttempt, privacy: .public)):
            \(String(describing: error), privacy: .public)
            Retrying in \(configureRetryDelay, privacy: .public)
            """,
          )
          try? await Task.sleep(for: configureRetryDelay)
          let nextRetryDelay = configureRetryDelay + configureRetryDelay
          configureRetryDelay =
            nextRetryDelay > maxConfigureRetryDelay ? maxConfigureRetryDelay : nextRetryDelay
        }
      }

      await subscribe()

      let wasActive = isAudioSessionActive
      await withCancellationOperation {
        if wasActive {
          do {
            try self.env.session.setActive(false, options: .notifyOthersOnDeactivation)
          } catch {
            log.error(
              "Failed to deactivate AudioSession on cancellation: \(error, privacy: .public)",
            )
          }
          await MainActor.run { self.isAudioSessionActive = false }
        }
      }

      let deactivationSuffix = wasActive ? ", deactivating AudioSession" : ""
      log.info(
        "🔇AudioEnvironmentManager.run() finished\(deactivationSuffix, privacy: .public)",
      )
    }
  }

  extension AudioEnvironmentManager {
    @discardableResult
    @MainActor
    private func updateAudioInputs(reason: String) -> AudioDeviceChangeSummary? {
      inputPreferenceController.updateAudioInputs(reason: reason)
    }

    struct AudioDeviceChangeSummary: Equatable, CustomStringConvertible {
      let addedInputs: [AudioInput]
      let removedInputs: [AudioInput]
      let addedSources: [AudioSource]
      let removedSources: [AudioSource]

      init(
        previousInputs: [AudioInput],
        currentInputs: [AudioInput],
        previousSources: [AudioSource],
        currentSources: [AudioSource],
      ) {
        let previousInputSet = Set(previousInputs)
        let currentInputSet = Set(currentInputs)

        addedInputs = currentInputSet.subtracting(previousInputSet).sorted()
        removedInputs = previousInputSet.subtracting(currentInputSet).sorted()

        let previousSourceSet = Set(previousSources)
        let currentSourceSet = Set(currentSources)

        addedSources = currentSourceSet.subtracting(previousSourceSet).sorted()
        removedSources = previousSourceSet.subtracting(currentSourceSet).sorted()
      }

      var description: String {
        let inputsDescription =
          "inputs + [\(addedInputs)], - [\(removedInputs)]"
        let sourcesDescription =
          "sources + [\(addedSources)], - [\(removedSources)]"
        return "\(inputsDescription), \(sourcesDescription)"
      }
    }

    private struct AudioEnvironmentState {
      let input: AudioInput?
      let selectedSource: AudioSource?
      let selectedSampleRate: SampleRate
      let availableInputs: [AudioInput]
      let availableSources: [AudioSource]
      let selectedNumberOfChannels: ChannelCount

      static func mirrored(
        env: AudioEnvironment,
        sourceFilter: ([AudioSource], ChannelCount) -> [AudioSource],
      ) -> Self {
        let selectedNumberOfChannels = env.input?.channelCount ?? .mono
        let availableSources = sourceFilter(env.availableSources, selectedNumberOfChannels)
        let selectedSource = env.source.flatMap { source in
          availableSources.first(where: { $0 == source })
        }
        return .init(
          input: env.input,
          selectedSource: selectedSource,
          selectedSampleRate: env.sampleRate,
          availableInputs: env.availableInputs,
          availableSources: availableSources,
          selectedNumberOfChannels: selectedNumberOfChannels,
        )
      }
    }

    private func filterSources(
      _ sources: [AudioSource],
      for channelCount: ChannelCount,
    ) -> [AudioSource] {
      guard channelCount.count > 1 else {
        return sources.filter { source in
          let patterns = source.supportedPolarPatterns
          guard !patterns.isEmpty else { return true }
          let supportsStereo = patterns.contains(.stereo)
          if !supportsStereo { return true }
          // Only exclude stereo-only sources when we are running in mono. If a source also
          // exposes any non-stereo polar pattern, we can continue to surface it.
          return patterns.contains(where: { $0 != .stereo })
        }
      }

      // When configured for stereo, surface only sources capable of stereo capture so the UI
      // never presents an option that would fail when selected.
      return sources.filter { source in
        let patterns = source.supportedPolarPatterns
        guard !patterns.isEmpty else { return true }
        return patterns.contains(.stereo)
      }
    }

    @MainActor
    private func dispatchInterruption(
      type: AudioInterruptionType,
      options: AudioInterruptionOptions?,
    ) async {
      await onInterruption?(type, options)
      await eventHub.dispatchInterruption(type: type, options: options)
    }

    @MainActor
    private func dispatchRouteChange(_ event: AudioRouteChangeEvent) async {
      await onRouteChange?(event)
      await eventHub.dispatchRouteChange(event)
    }

    @MainActor
    private func dispatchMediaServicesLost() async {
      await onMediaServicesLost?()
      await eventHub.dispatchMediaServicesLost()
    }

    @MainActor
    private func dispatchMediaServicesReset() async {
      await onMediaServicesReset?()
      await eventHub.dispatchMediaServicesReset()
    }

    /// Subscribes to all AVAudioSession notification streams.
    ///
    /// ## Threading Contract
    ///
    /// Each `for await` loop consumes an `AsyncStream` from
    /// ``AudioEnvironment/Notifications``. The stream's `compactMap`/`map` closures
    /// execute on Apple's internal "AVAudioSession Notify Thread" (parsing only,
    /// no mutable state). The `for await` body inherits this method's `@MainActor`
    /// isolation, so all handlers dispatch to MainActor automatically.
    private func subscribe() async {
      await withTaskGroup(of: Void.self) { group in
        let env = self.env

        group.addTask { [weak self] in
          for await notification in env.notifications.interruption {
            if Task.isCancelled { return }

            switch notification.type {
            case .began:
              await self?.dispatchInterruption(
                type: notification.type,
                options: notification.options,
              )
            case .ended:
              await self?.dispatchInterruption(
                type: notification.type,
                options: notification.options,
              )
            @unknown default:
              continue
            }
          }
        }
        group.addTask { [weak self] in
          for await _ in env.notifications.mediaServicesLost {
            if Task.isCancelled { return }
            await self?.handleMediaServicesLost()
          }
        }
        group.addTask { [weak self] in
          for await _ in env.notifications.mediaServicesReset {
            if Task.isCancelled { return }
            await self?.handleMediaServicesReset()
          }
        }
        routeObserver.addTasks(to: &group)
        group.addTask { [weak self] in
          await self?.subscribeToOrientation { @MainActor [weak self] orientation in
            guard let self else { return }
            _orientation = orientation
            log.info("orientation changed to: \(orientation.rawValue, privacy: .public)")
            guard orientation != .none else { return }
            do {
              if isConfiguredForStereo {
                try session.setPreferredInputOrientation(orientation)
              }
            } catch {
              errorManager.enqueue(error)
            }
          }
        }

        group.addTask { @Sendable @MainActor [weak self] in
          while !Task.isCancelled {
            guard let self else { return }
            let pollInterval: Duration
            if isAudioSessionActive {
              if let changes = updateAudioInputs(reason: "periodic poll") {
                log.info("􂡸 poll, device changes: \(changes, privacy: .public)")
              }
              pollInterval = .seconds(15)
            } else {
              pollInterval = .seconds(30)
            }
            try? await Task.sleep(for: pollInterval)
          }
        }

        group.addTask {
          Task { @MainActor in
            self.isReady = true
            log.info("🔊 AudioEnvironmentManager ready")
          }
          await withCancellationOperation {
            Task { @MainActor in
              self.isReady = false
            }
            log.info("🔇AudioEnvironmentManager cancelled")
          }
        }

        await group.waitForAll()
      }
    }
  }

  extension AudioEnvironmentManager {
    @MainActor
    private func handleMediaServicesLost() async {
      log.warning("mediaServicesLost notification: audio services unavailable")
      isAudioSessionActive = false
      await dispatchMediaServicesLost()
    }

    @MainActor
    private func handleMediaServicesReset() async {
      log.warning("mediaServicesReset notification: rebuilding audio session configuration")
      isAudioSessionActive = false
      do {
        try Self.configureAudioSessionCategory(
          env.session,
          configuration: sessionConfiguration,
        )
      } catch {
        errorManager.enqueue(error)
      }
      await restorePreferredInputAndConfigurationIfPossible(
        reason: "mediaServicesReset notification",
      )
      await dispatchMediaServicesReset()
    }
  }

  extension AudioEnvironmentManager {
    @MainActor
    private func restorePreferredInputAndConfigurationIfPossible(reason: String) async {
      await inputPreferenceRestorer.restorePreferredInputAndConfigurationIfPossible(reason: reason)
    }

    private func stereoPreferenceRank(_ source: AudioSource) -> Int {
      // Best-effort heuristic to pick a stable "good default" stereo mic when we can't restore
      // the exact prior data source. Tuned for built-in mic data sources.
      guard let raw = source.avAudio.location?.rawValue.lowercased() else { return 9 }

      // Common values observed in the wild include "lower"/"upper"/"front"/"back".
      // Prefer the typical "bottom" mic locations first for a stable default.
      if raw.contains("bottom") || raw.contains("lower") { return 0 }
      if raw.contains("front") { return 1 }
      if raw.contains("back") { return 2 }
      if raw.contains("top") || raw.contains("upper") { return 3 }
      return 9
    }
  }

  extension AudioEnvironmentManager {
    private struct AudioSessionBootstrap {
      let owner: AudioEnvironmentManager

      @MainActor
      func configureInitialSession(configuration: AudioSessionConfiguration) async throws(ManagerError)
      {
        let env = owner.env
        try AudioEnvironmentManager.configureAudioSessionCategory(
          env.session,
          configuration: configuration,
        )

        do {
          try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
              do {
                try env.request(
                  input: env.input
                    ?? env.availableInputs.first(where: { $0.platform.portType == .builtInMic }),
                )
              } catch let error as AudioEnvironment.RequestError {
                throw ManagerError.audioEnvironment(error)
              }
            }
            try await group.waitForAll()
          }

          await owner.restorePreferredInputAndConfigurationIfPossible(reason: "run() startup")
          logConfiguredSession(for: env)
        } catch let error as ManagerError {
          logFailedSession(for: env, error: error)
          throw error
        } catch {
          let mapped = ManagerError.unexpected(ErrorContext(error))
          logFailedSession(for: env, error: mapped)
          throw mapped
        }
      }

      @MainActor
      private func logConfiguredSession(for env: AudioEnvironment) {
        log.info(
          """
          🔊 AudioEnvironmentManager.run() configured AudioSession (inactive) with base settings:
          category: \(env.session.category.rawValue, privacy: .public)
          options: \(env.session.categoryOptions.description, privacy: .public)
          allowHapticsAndSystemSoundsDuringRecording: \(env.session.allowHapticsAndSystemSoundsDuringRecording, privacy: .public)
          prefersNoInterruptionsFromSystemAlerts: \(env.session.prefersNoInterruptionsFromSystemAlerts, privacy: .public)
          prefersInterruptionOnRouteDisconnect: \(env.session.prefersInterruptionOnRouteDisconnect, privacy: .public)
          """,
        )
      }

      @MainActor
      private func logFailedSession(for env: AudioEnvironment, error: ManagerError) {
        log.error(
          """
          🔊 AudioEnvironmentManager.run() failed:
          category: \(env.session.category.rawValue, privacy: .public)
          options: \(env.session.categoryOptions.description, privacy: .public)
          allowHapticsAndSystemSoundsDuringRecording: \(env.session.allowHapticsAndSystemSoundsDuringRecording, privacy: .public)
          prefersNoInterruptionsFromSystemAlerts: \(env.session.prefersNoInterruptionsFromSystemAlerts, privacy: .public)
          prefersInterruptionOnRouteDisconnect: \(env.session.prefersInterruptionOnRouteDisconnect, privacy: .public)
          error: \(error, privacy: .public)
          """,
        )
      }
    }

    private struct AudioSessionController {
      let owner: AudioEnvironmentManager

      @MainActor
      func setAudioSessionActive(_ active: Bool) throws(ManagerError) {
        guard owner.isRunning else {
          log.warning("Cannot set audio session active state when manager is not running")
          return
        }
        do {
          try owner.env.session.setActive(active, options: .notifyOthersOnDeactivation)
        } catch {
          throw .audioSessionFailed(operation: .setActive, error: ErrorContext(error))
        }
        owner.isAudioSessionActive = active
        log.info(
          "🔊 Audio session manually set to \(active ? "active" : "inactive", privacy: .public)",
        )
        if active {
          Task { @MainActor [weak owner] in
            await owner?.restorePreferredInputAndConfigurationIfPossible(
              reason: "audio session activated",
            )
          }
        }
      }
    }

    private struct AudioInputPreferenceController {
      let owner: AudioEnvironmentManager

      @MainActor
      func applyMono(persistPreference: Bool) async throws(ManagerError) {
        if persistPreference {
          persistInputPreferencesIfNeeded { prefs in
            prefs.channelCount = ChannelCount.mono.count
          }
        }

        var plan = InputConfigurationPlan()
        plan.channelCount = 1

        if let input = owner.env.input {
          let allSources: [AudioSource] = input.availableSources
          let current = owner.env.source

          var didApply = false
          if let current,
            let pattern = current.supportedPolarPatterns.first(where: { $0 != .stereo })
          {
            plan.polarPatternSource = current
            plan.polarPattern = pattern
            plan.preferredInput = input
            plan.preferredSource = current
            didApply = true
          }
          if !didApply,
            let monoCapable = allSources.first(where: { !$0.supportedPolarPatterns.contains(.stereo) }
            )
          {
            plan.preferredInput = input
            plan.preferredSource = monoCapable
            didApply = true
          }
          if !didApply,
            let fallback = allSources.first,
            let pattern = fallback.supportedPolarPatterns.first(where: { $0 != .stereo })
          {
            plan.polarPatternSource = fallback
            plan.polarPattern = pattern
            plan.preferredInput = input
            plan.preferredSource = fallback
          }
        }

        defer {
          owner.state = AudioEnvironmentState.mirrored(
            env: owner.env,
            sourceFilter: owner.filterSources,
          )
        }

        try await AudioEnvironmentManager.executeInputConfiguration(plan, session: owner.session)

        if persistPreference {
          persistInputPreferencesIfNeeded { prefs in
            prefs.sourceId = owner.env.source?.id
          }
        }
      }

      @MainActor
      func applyStereo(persistPreference: Bool) async throws(ManagerError) {
        if persistPreference {
          persistInputPreferencesIfNeeded { prefs in
            prefs.channelCount = ChannelCount.stereo.count
          }
        }
        do {
          if let input = owner.env.input {
            let allDataSources: [AudioSource] = input.availableSources
            let stereoCapableSources = allDataSources.filter {
              $0.supportedPolarPatterns.contains(.stereo)
            }

            let candidates = preferredStereoCandidates(from: stereoCapableSources)
            let session = owner.session
            let currentOrientation = owner.orientation

            try await Task.detached {
              var lastError: (any Error)?
              for stereoSource in candidates {
                do {
                  try stereoSource.set(preferredPolarPattern: .stereo)
                  try input.set(preferredSource: stereoSource)
                  if currentOrientation != .none {
                    try session.setPreferredInputOrientation(currentOrientation)
                  }
                  lastError = nil
                  break
                } catch {
                  lastError = error
                  continue
                }
              }
              if let lastError { throw lastError }
            }.value
          }

          owner.state = AudioEnvironmentState.mirrored(
            env: owner.env,
            sourceFilter: owner.filterSources,
          )
          if persistPreference {
            persistInputPreferencesIfNeeded { prefs in
              prefs.sourceId = owner.env.source?.id
            }
          }
        } catch let error as AudioSource.PreferenceError {
          try await applyMono(persistPreference: false)
          throw .audioSource(error)
        } catch let error as AudioInput.PreferenceError {
          try await applyMono(persistPreference: false)
          throw .audioInput(error)
        } catch let error as ManagerError {
          try await applyMono(persistPreference: false)
          throw error
        } catch {
          let mapped = ManagerError.unexpected(ErrorContext(error))
          try await applyMono(persistPreference: false)
          throw mapped
        }
      }

      @discardableResult
      @MainActor
      func updateAudioInputs(reason: String) -> AudioDeviceChangeSummary? {
        let previousState = owner.state
        let nextState = AudioEnvironmentState.mirrored(
          env: owner.env,
          sourceFilter: owner.filterSources,
        )
        guard nextState.availableInputs != previousState.availableInputs
          || nextState.availableSources != previousState.availableSources
        else {
          return nil
        }

        owner.state = nextState
        let summary = AudioDeviceChangeSummary(
          previousInputs: previousState.availableInputs,
          currentInputs: nextState.availableInputs,
          previousSources: previousState.availableSources,
          currentSources: nextState.availableSources,
        )
        log.info("\(reason, privacy: .public): \(summary.description, privacy: .public)")
        return summary
      }

      private func persistInputPreferencesIfNeeded(
        _ update: (inout PersistedInputPreferences) -> Void,
      ) {
        guard !owner.isRestoringFromDefaults else { return }

        let inputId = owner.env.input?.id ?? "_default"
        owner.preferenceStore.update(
          inputId: inputId,
          currentSampleRate: owner.env.sampleRate,
          isConfiguredForStereo: owner.isConfiguredForStereo,
          currentSourceId: owner.env.source?.id,
          update,
        )
      }

      private func preferredStereoCandidates(from stereoSources: [AudioSource]) -> [AudioSource] {
        guard !stereoSources.isEmpty else { return [] }

        let inputId = owner.env.input?.id ?? "_default"
        let preferredSourceId = owner.preferenceStore.preferences(for: inputId)?.sourceId

        var ordered: [AudioSource] = []
        ordered.reserveCapacity(stereoSources.count)

        if let preferredSourceId,
          let preferred = stereoSources.first(where: { $0.id == preferredSourceId })
        {
          ordered.append(preferred)
        }

        if let current = owner.selectedSource, stereoSources.contains(current), !ordered.contains(current)
        {
          ordered.append(current)
        }

        let remaining =
          stereoSources
          .filter { !ordered.contains($0) }
          .sorted { lhs, rhs in
            let l = owner.stereoPreferenceRank(lhs)
            let r = owner.stereoPreferenceRank(rhs)
            if l != r { return l < r }
            return lhs.name < rhs.name
          }
        ordered.append(contentsOf: remaining)
        return ordered
      }
    }

    private struct AudioInputPreferenceRestorer {
      let owner: AudioEnvironmentManager

      @MainActor
      func restorePreferredInputAndConfigurationIfPossible(reason: String) async {
        guard !owner.isRestoringFromDefaults else { return }
        owner.isRestoringFromDefaults = true
        defer { owner.isRestoringFromDefaults = false }

        owner.preferenceStore.reload()

        if !owner.isAudioSessionActive,
          let preferredInputId = owner.preferenceStore.preferredInputId,
          let preferredInput = owner.env.availableInputs.first(where: { $0.id == preferredInputId }),
          owner.env.input?.id != preferredInputId
        {
          do {
            try owner.env.request(input: preferredInput)
          } catch {
            owner.errorManager.enqueue(error)
          }
        }

        owner.state = AudioEnvironmentState.mirrored(
          env: owner.env,
          sourceFilter: owner.filterSources,
        )

        let inputId = owner.env.input?.id ?? "_default"
        let canApplyPreferences = owner.isAudioSessionActive
        let modeStatus = canApplyPreferences ? "applied" : "deferred"
        if let prefs = owner.preferenceStore.preferences(for: inputId) {
          if canApplyPreferences {
            if let sampleRateHz = prefs.sampleRateHz {
              owner.sampleRate = SampleRate(rawValue: sampleRateHz)
            }

            if let channelCount = prefs.channelCount {
              do {
                if channelCount > 1 {
                  try await owner.applyStereo()
                } else {
                  try await owner.applyMono()
                }
              } catch {
                owner.errorManager.enqueue(error)
              }
            }

            if let sourceId = prefs.sourceId {
              let desired = owner.availableSources.first(where: { $0.id == sourceId })
              if desired != nil {
                owner.selectedSource = desired
              } else if owner.inputHasStereoSource, owner.shouldAutoSelectStereoWhenAvailable == false {
                do {
                  try await owner.applyStereo()
                } catch {
                  owner.errorManager.enqueue(error)
                }
              }
            }
          } else {
            log.info(
              "Skipping input preference restore; audio session inactive (\(reason, privacy: .public))",
            )
          }
        } else if canApplyPreferences {
          if owner.inputHasStereoSource {
            do {
              try await owner.applyStereo()
            } catch {
              owner.errorManager.enqueue(error)
            }
          }
        } else {
          log.info(
            "Skipping input preference defaults; audio session inactive (\(reason, privacy: .public))",
          )
        }

        log.info(
          "Restored audio environment preferences (\(reason, privacy: .public); \(modeStatus, privacy: .public))",
        )
      }
    }

    private struct AudioRouteObserver {
      let owner: AudioEnvironmentManager

      func addTasks(to group: inout TaskGroup<Void>) {
        let env = owner.env
        group.addTask { [weak owner] in
          for await _ in env.notifications.availableInputsChanged {
            guard let owner else { return }
            await owner.updateAudioInputs(reason: "availableInputsChanged notification")
          }
        }
        group.addTask { [weak owner] in
          for await notification in env.notifications.routeChange {
            log.info(
              "Route change notification: \(String(describing: notification), privacy: .public)",
            )
            if Task.isCancelled { return }
            guard let owner else { return }
            let reasonMsg =
              switch notification.reason {
              case .oldDeviceUnavailable: "oldDeviceUnavailable"
              case .categoryChange: "categoryChange"
              case .newDeviceAvailable: "newDeviceAvailable"
              case .noSuitableRouteForCategory: "noSuitableRouteForCategory"
              case .override: "override"
              case .routeConfigurationChange: "routeConfigurationChange"
              case .wakeFromSleep: "wakeFromSleep"
              case .unknown: "unknown"
              @unknown default: "unknowndefault"
              }
            await owner.updateAudioInputs(reason: "routeChange notification: .\(reasonMsg)")
            if await !owner.isAudioSessionActive,
              notification.reason == .newDeviceAvailable
                || notification.reason == .oldDeviceUnavailable
            {
              await owner.restorePreferredInputAndConfigurationIfPossible(
                reason: "routeChange notification: .\(reasonMsg)",
              )
            }

            let event = AudioRouteChangeEvent(
              reason: notification.reason,
              previousRoute: notification.previous,
              session: env.session,
            )
            await owner.dispatchRouteChange(event)
          }
        }
      }
    }
  }

  extension Array where Element: Hashable {
    func removingDuplicates() -> Self {
      var set = Set<Element>()
      return filter {
        set.insert($0).inserted
      }
    }
  }

#endif
