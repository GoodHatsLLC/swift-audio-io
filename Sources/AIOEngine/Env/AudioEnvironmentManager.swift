#if canImport(AVFoundation) && (!os(macOS) || targetEnvironment(macCatalyst))
  public import Tools
  public import AVFAudio
  import Combine
  import Foundation
  public import Observation
  import os
  import SystemLog

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
  public class AudioEnvironmentManager {
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
          configuration: .recorderDefault
        )
      } catch {
        log.error(
          "Failed to prepare audio session category on launch: \(error.localizedDescription, privacy: .public)"
        )
      }
    }

    /// Configures the audio session category/options, but does not activate the session.
    ///
    /// Activation (`setActive(true)`) is intentionally separated so the app can avoid claiming the
    /// microphone/audio session until explicitly requested.
    public nonisolated static func configureAudioSessionCategory(
      _ session: AVAudioSession,
      configuration: AudioSessionConfiguration
    ) throws(ManagerError) {
      do {
        try session.setCategory(
          configuration.category,
          mode: configuration.mode,
          options: configuration.options
        )
      } catch {
        throw .audioSessionFailed(operation: .setCategory, error: ErrorContext(error))
      }

      do {
        try session.setAllowHapticsAndSystemSoundsDuringRecording(
          configuration.allowsHapticsAndSystemSoundsDuringRecording
        )
      } catch {
        throw .audioSessionFailed(
          operation: .setAllowHapticsAndSystemSoundsDuringRecording,
          error: ErrorContext(error)
        )
      }

      do {
        try session.setPrefersNoInterruptionsFromSystemAlerts(
          configuration.prefersNoInterruptionsFromSystemAlerts
        )
      } catch {
        throw .audioSessionFailed(
          operation: .setPrefersNoInterruptionsFromSystemAlerts,
          error: ErrorContext(error)
        )
      }

      do {
        try session.setPrefersInterruptionOnRouteDisconnect(
          configuration.prefersInterruptionOnRouteDisconnect
        )
      } catch {
        throw .audioSessionFailed(
          operation: .setPrefersInterruptionOnRouteDisconnect,
          error: ErrorContext(error)
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
      defaults: UserDefaults = .standard
    ) {
      self.env = env
      self.errorManager = errorManager
      self.defaults = defaults
      _input = env.input
      _availableInputs = env.availableInputs
      _selectedSource = env.input?.selectedSource
      _selectedSampleRate = env.sampleRate
      _availableSources = env.input?.availableSources ?? []
      _orientation = .none
      _selectedNumberOfChannels = (env.input?.channelCount) ?? .mono
      self.persistedInputPreferencesById = Self.loadInputPreferences(from: defaults)
    }
    private let env: AudioEnvironment
    /// The underlying `AVAudioSession`.
    public var session: AVAudioSession { env.session }
    /// The preferred category/mode/options for this environment.
    public var sessionConfiguration: AudioSessionConfiguration = .recorderDefault
    private let errorManager: any ErrorManaging
    private let defaults: UserDefaults

    private struct PersistedInputPreferences: Codable, Sendable {
      var sampleRateHz: Double?
      var channelCount: Int?
      var sourceId: String?
    }

    private enum StorageKey {
      static let preferredInputId = "aio.audio_env.preferred_input_id.v1"
      static let inputPrefsById = "aio.audio_env.input_prefs_by_id.v1"
    }

    private var persistedInputPreferencesById: [String: PersistedInputPreferences] = [:]
    private var isRestoringFromDefaults: Bool = false

    public var shouldAutoSelectStereoWhenAvailable: Bool {
      let inputId = env.input?.id ?? "_default"
      return persistedInputPreferencesById[inputId] == nil
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
              context: "Audio session"
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

    private var routeChangeSubscribers:
      [UUID: (@Sendable @MainActor (AudioRouteChangeEvent) async -> Void)] =
        [:]
    private var interruptionSubscribers:
      [UUID:
        (
          @Sendable @MainActor (
            AVAudioSession.InterruptionType, AVAudioSession.InterruptionOptions?
          )
            async -> Void
        )] = [:]
    private var mediaServicesLostSubscribers: [UUID: (@Sendable @MainActor () async -> Void)] = [:]
    private var mediaServicesResetSubscribers: [UUID: (@Sendable @MainActor () async -> Void)] = [:]

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

    @discardableResult
    public func addRouteChangeSubscriber(
      _ handler: @escaping @Sendable @MainActor (AudioRouteChangeEvent) async -> Void
    ) -> UUID {
      let id = UUID()
      routeChangeSubscribers[id] = handler
      return id
    }

    @discardableResult
    public func addInterruptionSubscriber(
      _ handler:
        @escaping @Sendable @MainActor (
          AVAudioSession.InterruptionType, AVAudioSession.InterruptionOptions?
        ) async -> Void
    ) -> UUID {
      let id = UUID()
      interruptionSubscribers[id] = handler
      return id
    }

    @discardableResult
    public func addMediaServicesLostSubscriber(
      _ handler: @escaping @Sendable @MainActor () async -> Void
    ) -> UUID {
      let id = UUID()
      mediaServicesLostSubscribers[id] = handler
      return id
    }

    @discardableResult
    public func addMediaServicesResetSubscriber(
      _ handler: @escaping @Sendable @MainActor () async -> Void
    ) -> UUID {
      let id = UUID()
      mediaServicesResetSubscribers[id] = handler
      return id
    }

    public func removeSubscriber(_ id: UUID) {
      routeChangeSubscribers.removeValue(forKey: id)
      interruptionSubscribers.removeValue(forKey: id)
      mediaServicesLostSubscribers.removeValue(forKey: id)
      mediaServicesResetSubscribers.removeValue(forKey: id)
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
                """
              )
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
            """
          )
        if persistPreference {
          // Persist the actual device rate on failure so we don't repeatedly retry
          // an unsupported preference for this input across route changes.
          persistInputPreferencesIfNeeded { prefs in
            prefs.sampleRateHz = actual.rawValue
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
          defaults.set(env.input?.id, forKey: StorageKey.preferredInputId)
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
      let resolvedChannels: ChannelCount

      if sessionChannels > 0 {
        resolvedChannels = .init(platform: AVAudioChannelCount(sessionChannels))
      } else {
        resolvedChannels = _selectedNumberOfChannels
      }

      return .init(
        sampleRate: .init(rawValue: sampleRate),
        channels: resolvedChannels
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
    public func applyMono() throws(ManagerError) {
      try applyMono(persistPreference: true)
    }

    public func applyMono(persistPreference: Bool) throws(ManagerError) {
      try applyMonoInternal(persistPreference: persistPreference)
    }

    private func applyMonoInternal(persistPreference: Bool) throws(ManagerError) {
      if persistPreference {
        persistInputPreferencesIfNeeded { prefs in
          prefs.channelCount = ChannelCount.mono.count
        }
      }
      // Force mono input at the session level and clear orientation
      do {
        try session.setPreferredInputNumberOfChannels(1)
      } catch {
        throw .audioSessionFailed(
          operation: .setPreferredInputNumberOfChannels,
          error: ErrorContext(error)
        )
      }

      // Prefer to keep the current input, but switch to a non-stereo polar pattern/source
      if let input = env.input {
        let allSources: [AudioSource] = input.availableSources
        let current = env.source

        var didApply = false
        // 1) Try to keep the current source but switch its pattern to non-stereo
        if let current,
          let pattern = current.supportedPolarPatterns.first(where: { $0 != .stereo })
        {
          if let error: AudioSource.PreferenceError = {
            do {
              try current.set(preferredPolarPattern: pattern)
              return nil
            } catch let error as AudioSource.PreferenceError {
              return error
            } catch {
              preconditionFailure("Unexpected error type: \(error)")
            }
          }() {
            throw .audioSource(error)
          }

          if let error: AudioInput.PreferenceError = {
            do {
              try input.set(preferredSource: current)
              return nil
            } catch let error as AudioInput.PreferenceError {
              return error
            } catch {
              preconditionFailure("Unexpected error type: \(error)")
            }
          }() {
            throw .audioInput(error)
          }
          didApply = true
        }
        // 2) If that fails, select a source that doesn't support stereo at all
        if !didApply,
          let monoCapable = allSources.first(where: { !$0.supportedPolarPatterns.contains(.stereo) }
          )
        {
          if let error: AudioInput.PreferenceError = {
            do {
              try input.set(preferredSource: monoCapable)
              return nil
            } catch let error as AudioInput.PreferenceError {
              return error
            } catch {
              preconditionFailure("Unexpected error type: \(error)")
            }
          }() {
            throw .audioInput(error)
          }
          didApply = true
        }
        // 3) As a last resort, pick the first source and force a non-stereo pattern if available
        if !didApply,
          let fallback = allSources.first,
          let pattern = fallback.supportedPolarPatterns.first(where: { $0 != .stereo })
        {
          if let error: AudioSource.PreferenceError = {
            do {
              try fallback.set(preferredPolarPattern: pattern)
              return nil
            } catch let error as AudioSource.PreferenceError {
              return error
            } catch {
              preconditionFailure("Unexpected error type: \(error)")
            }
          }() {
            throw .audioSource(error)
          }

          if let error: AudioInput.PreferenceError = {
            do {
              try input.set(preferredSource: fallback)
              return nil
            } catch let error as AudioInput.PreferenceError {
              return error
            } catch {
              preconditionFailure("Unexpected error type: \(error)")
            }
          }() {
            throw .audioInput(error)
          }
        }
      }

      // Refresh cached mirrors
      _input = env.input
      _selectedNumberOfChannels = (env.input?.channelCount) ?? .mono
      _availableInputs = env.availableInputs
      _selectedSource = env.source
      _availableSources = filterSources(env.availableSources, for: _selectedNumberOfChannels)
      if persistPreference {
        persistInputPreferencesIfNeeded { prefs in
          prefs.sourceId = env.source?.id
        }
      }
    }

    /// Applies a stereo audio configuration.
    ///
    /// This method attempts to select a stereo-capable audio source and polar pattern. If it fails, it falls back to a mono configuration.
    ///
    /// - Throws: An error if the audio session cannot be configured for stereo.
    public func applyStereo() throws(ManagerError) {
      try applyStereo(persistPreference: true)
    }

    public func applyStereo(persistPreference: Bool) throws(ManagerError) {
      try applyStereoInternal(persistPreference: persistPreference)
    }

    private func applyStereoInternal(persistPreference: Bool) throws(ManagerError) {
      if persistPreference {
        persistInputPreferencesIfNeeded { prefs in
          prefs.channelCount = ChannelCount.stereo.count
        }
      }
      do {
        if let input = env.input {
          let allDataSources: [AudioSource] = input.availableSources

          // Try to find a stereo-capable source, preferring the currently selected one
          let stereoCapableSources = allDataSources.filter {
            $0.supportedPolarPatterns.contains(.stereo)
          }

          let candidates = preferredStereoCandidates(from: stereoCapableSources)
          var lastError: (any Error)?

          for stereoSource in candidates {
            do {
              if let error: AudioSource.PreferenceError = {
                do {
                  try stereoSource.set(preferredPolarPattern: .stereo)
                  return nil
                } catch let error as AudioSource.PreferenceError {
                  return error
                } catch {
                  preconditionFailure("Unexpected error type: \(error)")
                }
              }() {
                throw ManagerError.audioSource(error)
              }

              if let error: AudioInput.PreferenceError = {
                do {
                  try input.set(preferredSource: stereoSource)
                  return nil
                } catch let error as AudioInput.PreferenceError {
                  return error
                } catch {
                  preconditionFailure("Unexpected error type: \(error)")
                }
              }() {
                throw ManagerError.audioInput(error)
              }

              let currentOrientation = orientation
              if currentOrientation != .none {
                do {
                  try session.setPreferredInputOrientation(currentOrientation)
                } catch {
                  throw ManagerError.audioSessionFailed(
                    operation: .setPreferredInputOrientation,
                    error: ErrorContext(error)
                  )
                }
              }

              lastError = nil
              break
            } catch {
              lastError = error
              continue
            }
          }

          if let lastError {
            throw lastError
          }
        }

        // Refresh cached mirrors to match applyMono()
        _input = env.input
        _selectedNumberOfChannels = (env.input?.channelCount) ?? .mono
        _availableInputs = env.availableInputs
        _selectedSource = env.source
        _availableSources = filterSources(env.availableSources, for: _selectedNumberOfChannels)
        if persistPreference {
          persistInputPreferencesIfNeeded { prefs in
            prefs.sourceId = env.source?.id
          }
        }
      } catch let error as ManagerError {
        try applyMonoInternal(persistPreference: false)
        throw error
      } catch {
        let mapped = ManagerError.unexpected(ErrorContext(error))
        try applyMonoInternal(persistPreference: false)
        throw mapped
      }
    }

    /// Manually sets the audio session active state.
    ///
    /// This allows enabling or disabling the audio session independently of recording.
    /// When active, the app claims the audio session and can receive audio input.
    ///
    /// - Parameter active: Whether the audio session should be active.
    /// - Throws: An error if the audio session state cannot be changed.
    public func setAudioSessionActive(_ active: Bool) throws(ManagerError) {
      guard isRunning else {
        log.warning("Cannot set audio session active state when manager is not running")
        return
      }
      do {
        try env.session.setActive(active, options: .notifyOthersOnDeactivation)
      } catch {
        throw .audioSessionFailed(operation: .setActive, error: ErrorContext(error))
      }
      isAudioSessionActive = active
      log.info(
        "🔊 Audio session manually set to \(active ? "active" : "inactive", privacy: .public)")
      if active {
        restorePreferredInputAndConfigurationIfPossible(
          reason: "audio session activated"
        )
      }
    }

  }

  extension AudioEnvironmentManager {
    @MainActor
    private func subscribeToOrientation(
      _ onChange: @MainActor (AVAudioSession.StereoOrientation) -> Void
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

      /// Within this task group:
      /// - teardown symmetric with setup must always happen
      /// - it should be applied at the same level of nesting as its setup
      /// - the end effect once returning should be that `run()` is ready to be called
      await withThrowingTaskGroup(of: Void.self) { group in
        func configureAudioSession(
          env: AudioEnvironment,
          configuration: AudioSessionConfiguration
        ) {
          group.addTask {
            do {
              // Configure audio session category/options early, but do NOT activate.
              // Activation should only occur when the app expresses intent to record or play audio.
              try Self.configureAudioSessionCategory(
                env.session,
                configuration: configuration
              )
              do {
                try env.request(
                  input: env.input
                    ?? env.availableInputs.first(where: { $0.platform.portType == .builtInMic }
                    )
                )
              } catch let error as AudioEnvironment.RequestError {
                throw ManagerError.audioEnvironment(error)
              }

              await MainActor.run {
                self.restorePreferredInputAndConfigurationIfPossible(reason: "run() startup")
              }

              log.info(
                """
                🔊 AudioEnvironmentManager.run() configured AudioSession (inactive) with base settings:
                category: \(env.session.category.rawValue, privacy: .public)
                options: \(env.session.categoryOptions.description, privacy: .public)
                allowHapticsAndSystemSoundsDuringRecording: \(env.session.allowHapticsAndSystemSoundsDuringRecording, privacy: .public)
                prefersNoInterruptionsFromSystemAlerts: \(env.session.prefersNoInterruptionsFromSystemAlerts, privacy: .public)
                prefersInterruptionOnRouteDisconnect: \(env.session.prefersInterruptionOnRouteDisconnect, privacy: .public)
                """
              )
            } catch let error as ManagerError {
              log.error(
                """
                🔊 AudioEnvironmentManager.run() failed:
                category: \(env.session.category.rawValue, privacy: .public)
                options: \(env.session.categoryOptions.description, privacy: .public)
                allowHapticsAndSystemSoundsDuringRecording: \(env.session.allowHapticsAndSystemSoundsDuringRecording, privacy: .public)
                prefersNoInterruptionsFromSystemAlerts: \(env.session.prefersNoInterruptionsFromSystemAlerts, privacy: .public)
                prefersInterruptionOnRouteDisconnect: \(env.session.prefersInterruptionOnRouteDisconnect, privacy: .public)
                error: \(error, privacy: .public)
                """
              )
              throw error
            } catch {
              let mapped = ManagerError.unexpected(ErrorContext(error))
              log.error(
                """
                🔊 AudioEnvironmentManager.run() failed:
                category: \(env.session.category.rawValue, privacy: .public)
                options: \(env.session.categoryOptions.description, privacy: .public)
                allowHapticsAndSystemSoundsDuringRecording: \(env.session.allowHapticsAndSystemSoundsDuringRecording, privacy: .public)
                prefersNoInterruptionsFromSystemAlerts: \(env.session.prefersNoInterruptionsFromSystemAlerts, privacy: .public)
                prefersInterruptionOnRouteDisconnect: \(env.session.prefersInterruptionOnRouteDisconnect, privacy: .public)
                error: \(mapped, privacy: .public)
                """
              )
              throw mapped
            }
          }
        }

        // Wait for session configuration to complete before starting notifications
        var isConfigured = false
        var configureAttempt = 0
        var configureRetryDelay: Duration = .milliseconds(100)
        let maxConfigureRetryDelay: Duration = .seconds(2)
        while !isConfigured {
          configureAttempt += 1
          do {
            let (env, configuration) = await MainActor.run {
              (self.env, self.sessionConfiguration)
            }
            configureAudioSession(env: env, configuration: configuration)
            _ = try await group.next()
            isConfigured = true
          } catch {
            if Task.isCancelled {
              return
            } else {
              log.error(
                """
                Engine failed to configure audio session (attempt \(configureAttempt, privacy: .public)):
                \(String(describing: error), privacy: .public)
                Retrying in \(configureRetryDelay, privacy: .public)
                """
              )
              try? await Task.sleep(for: configureRetryDelay)
              let nextRetryDelay = configureRetryDelay + configureRetryDelay
              configureRetryDelay =
                nextRetryDelay > maxConfigureRetryDelay ? maxConfigureRetryDelay : nextRetryDelay
            }
          }
        }

        group.addTask { [weak self] in
          guard let self else { return }
          await self.subscribe()
        }
      }

      let wasActive = isAudioSessionActive
      await withCancellationOperation {
        if wasActive {
          do {
            try self.env.session.setActive(false, options: .notifyOthersOnDeactivation)
          } catch {
            log.error(
              "Failed to deactivate AudioSession on cancellation: \(error, privacy: .public)")
          }
          await MainActor.run { self.isAudioSessionActive = false }
        }
      }

      let deactivationSuffix = wasActive ? ", deactivating AudioSession" : ""
      log.info(
        "🔇AudioEnvironmentManager.run() finished\(deactivationSuffix, privacy: .public)"
      )
    }
  }

  extension AudioEnvironmentManager {

    @discardableResult
    @MainActor
    private func updateAudioInputs(reason: String) -> AudioDeviceChangeSummary? {
      let updatedInputs = env.availableInputs
      let rawSources = env.availableSources

      // Refresh the cached channel configuration before filtering sources so we react to
      // changes triggered by external route updates (e.g. plugging in a stereo mic).
      _selectedNumberOfChannels = env.input?.channelCount ?? .mono

      let filteredSources = filterSources(rawSources, for: _selectedNumberOfChannels)

      guard updatedInputs != _availableInputs || filteredSources != _availableSources else {
        return nil
      }

      let previousInputs = _availableInputs
      let previousSources = _availableSources

      _input = env.input
      _selectedSampleRate = env.sampleRate
      _availableInputs = updatedInputs

      let selectedSource = env.source
      _selectedSource = selectedSource.flatMap { source in
        filteredSources.first(where: { $0 == source })
      }
      _availableSources = filteredSources

      let summary = AudioDeviceChangeSummary(
        previousInputs: previousInputs,
        currentInputs: updatedInputs,
        previousSources: previousSources,
        currentSources: filteredSources
      )
      let changeMsg = summary.description
      log.info("\(reason, privacy: .public): \(changeMsg, privacy: .public)")
      return summary
    }

    struct AudioDeviceChangeSummary: Equatable, Sendable, CustomStringConvertible {
      let addedInputs: [AudioInput]
      let removedInputs: [AudioInput]
      let addedSources: [AudioSource]
      let removedSources: [AudioSource]

      init(
        previousInputs: [AudioInput],
        currentInputs: [AudioInput],
        previousSources: [AudioSource],
        currentSources: [AudioSource]
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

    private func filterSources(
      _ sources: [AudioSource],
      for channelCount: ChannelCount
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
      type: AVAudioSession.InterruptionType,
      options: AVAudioSession.InterruptionOptions?
    ) async {
      await onInterruption?(type, options)
      for subscriber in interruptionSubscribers.values {
        await subscriber(type, options)
      }
    }

    @MainActor
    private func dispatchRouteChange(_ event: AudioRouteChangeEvent) async {
      await onRouteChange?(event)
      for subscriber in routeChangeSubscribers.values {
        await subscriber(event)
      }
    }

    @MainActor
    private func dispatchMediaServicesLost() async {
      await onMediaServicesLost?()
      for subscriber in mediaServicesLostSubscribers.values {
        await subscriber()
      }
    }

    @MainActor
    private func dispatchMediaServicesReset() async {
      await onMediaServicesReset?()
      for subscriber in mediaServicesResetSubscribers.values {
        await subscriber()
      }
    }

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
                options: notification.options
              )
            case .ended:
              await self?.dispatchInterruption(
                type: notification.type,
                options: notification.options
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
        group.addTask { [weak self] in
          for await _ in env.notifications.availableInputsChanged {
            guard let self else { return }
            await self.updateAudioInputs(reason: "availableInputsChanged notification")
          }
        }
        group.addTask { [weak self] in
          for await notification in env.notifications.routeChange {
            log.info(
              "Route change notification: \(String(describing: notification), privacy: .public)")
            if Task.isCancelled { return }
            guard let self else { return }
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
            await self.updateAudioInputs(reason: "routeChange notification: .\(reasonMsg)")
            await MainActor.run { [weak self] in
              guard let self else { return }
              if !self.isAudioSessionActive
                && (notification.reason == .newDeviceAvailable
                  || notification.reason == .oldDeviceUnavailable)
              {
                self.restorePreferredInputAndConfigurationIfPossible(
                  reason: "routeChange notification: .\(reasonMsg)"
                )
              }
            }

            // Forward route change to audio engine
            let event = AudioRouteChangeEvent(
              reason: notification.reason,
              previousRoute: notification.previous,
              session: env.session
            )
            await self.dispatchRouteChange(event)
          }
        }
        group.addTask { [weak self] in
          await self?.subscribeToOrientation { @MainActor [weak self] orientation in
            guard let self else { return }
            self._orientation = orientation
            log.info("orientation changed to: \(orientation.rawValue, privacy: .public)")
            guard orientation != .none else { return }
            do {
              if self.isConfiguredForStereo {
                try self.session.setPreferredInputOrientation(orientation)
              }
            } catch {
              self.errorManager.enqueue(error)
            }
          }
        }

        group.addTask { @Sendable @MainActor [weak self] in
          while !Task.isCancelled {
            guard let self else { return }
            let pollInterval: Duration
            if self.isAudioSessionActive {
              if let changes = self.updateAudioInputs(reason: "periodic poll") {
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
          configuration: sessionConfiguration
        )
      } catch {
        errorManager.enqueue(error)
      }
      restorePreferredInputAndConfigurationIfPossible(
        reason: "mediaServicesReset notification"
      )
      await dispatchMediaServicesReset()
    }
  }

  extension AudioEnvironmentManager {
    @MainActor
    private func restorePreferredInputAndConfigurationIfPossible(reason: String) {
      guard !isRestoringFromDefaults else { return }
      isRestoringFromDefaults = true
      defer { isRestoringFromDefaults = false }

      persistedInputPreferencesById = Self.loadInputPreferences(from: defaults)

      if !isAudioSessionActive,
        let preferredInputId = defaults.string(forKey: StorageKey.preferredInputId),
        let preferredInput = env.availableInputs.first(where: { $0.id == preferredInputId }),
        env.input?.id != preferredInputId
      {
        do {
          try env.request(input: preferredInput)
        } catch {
          errorManager.enqueue(error)
        }
      }

      // Refresh cached mirrors before applying per-input preferences.
      _input = env.input
      _selectedSampleRate = env.sampleRate
      _selectedNumberOfChannels = (env.input?.channelCount) ?? .mono
      _availableInputs = env.availableInputs
      _selectedSource = env.source
      _availableSources = filterSources(env.availableSources, for: _selectedNumberOfChannels)

      let inputId = env.input?.id ?? "_default"
      let canApplyPreferences = isAudioSessionActive
      let modeStatus = canApplyPreferences ? "applied" : "deferred"
      if let prefs = persistedInputPreferencesById[inputId] {
        if canApplyPreferences {
          if let sampleRateHz = prefs.sampleRateHz {
            self.sampleRate = SampleRate(rawValue: sampleRateHz)
          }

          if let channelCount = prefs.channelCount {
            do {
              if channelCount > 1 {
                try applyStereo()
              } else {
                try applyMono()
              }
            } catch {
              errorManager.enqueue(error)
            }
          }

          if let sourceId = prefs.sourceId {
            let desired = _availableSources.first(where: { $0.id == sourceId })
            if desired != nil {
              selectedSource = desired
            } else if inputHasStereoSource, shouldAutoSelectStereoWhenAvailable == false {
              // Best-effort fallback: choose another stereo-capable source when the remembered one
              // is no longer available.
              do {
                try applyStereo()
              } catch {
                errorManager.enqueue(error)
              }
            }
          }
        } else {
          log.info(
            "Skipping input preference restore; audio session inactive (\(reason, privacy: .public))"
          )
        }
      } else if canApplyPreferences {
        // First-run default: prefer stereo if available.
        if inputHasStereoSource {
          do {
            try applyStereo()
          } catch {
            errorManager.enqueue(error)
          }
        }
      } else {
        log.info(
          "Skipping input preference defaults; audio session inactive (\(reason, privacy: .public))"
        )
      }

      log.info(
        "Restored audio environment preferences (\(reason, privacy: .public); \(modeStatus, privacy: .public))"
      )
    }

    private func persistInputPreferencesIfNeeded(
      _ update: (inout PersistedInputPreferences) -> Void
    ) {
      guard !isRestoringFromDefaults else { return }

      let inputId = env.input?.id ?? "_default"
      defaults.set(inputId, forKey: StorageKey.preferredInputId)

      var prefs =
        persistedInputPreferencesById[inputId]
        ?? PersistedInputPreferences(
          sampleRateHz: env.sampleRate.rawValue,
          channelCount: isConfiguredForStereo ? 2 : 1,
          sourceId: env.source?.id
        )
      update(&prefs)

      persistedInputPreferencesById[inputId] = prefs
      guard let data = try? JSONEncoder().encode(persistedInputPreferencesById) else { return }
      defaults.set(data, forKey: StorageKey.inputPrefsById)
    }

    private static func loadInputPreferences(
      from defaults: UserDefaults
    ) -> [String: PersistedInputPreferences] {
      guard let data = defaults.data(forKey: StorageKey.inputPrefsById) else { return [:] }
      return (try? JSONDecoder().decode([String: PersistedInputPreferences].self, from: data))
        ?? [:]
    }

    private func preferredStereoCandidates(from stereoSources: [AudioSource]) -> [AudioSource] {
      guard !stereoSources.isEmpty else { return [] }

      let inputId = env.input?.id ?? "_default"
      let preferredSourceId = persistedInputPreferencesById[inputId]?.sourceId

      var ordered: [AudioSource] = []
      ordered.reserveCapacity(stereoSources.count)

      if let preferredSourceId,
        let preferred = stereoSources.first(where: { $0.id == preferredSourceId })
      {
        ordered.append(preferred)
      }

      if let current = selectedSource, stereoSources.contains(current), !ordered.contains(current) {
        ordered.append(current)
      }

      let remaining =
        stereoSources
        .filter { !ordered.contains($0) }
        .sorted { lhs, rhs in
          let l = stereoPreferenceRank(lhs)
          let r = stereoPreferenceRank(rhs)
          if l != r { return l < r }
          return lhs.name < rhs.name
        }
      ordered.append(contentsOf: remaining)
      return ordered
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
#endif
