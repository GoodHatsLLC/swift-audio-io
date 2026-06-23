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

    let env: AudioEnvironment
    /// The underlying `AVAudioSession`.
    public var session: AVAudioSession {
      env.session
    }

    /// The preferred category/mode/options for this environment.
    public var sessionConfiguration: AudioSessionConfiguration = .recordingConfiguration
    let errorManager: any ErrorManaging
    let preferenceStore: AudioEnvironmentPreferenceStore
    @ObservationIgnored var callbackTasks = MainActorTaskRunner()
    /// Serializes every AVAudioSession input-preference XPC mutation — the
    /// bindable setters (`setSelectedInput`/`setSelectedSource`/`setSampleRate`),
    /// `applyMono`/`applyStereo`/`applySourceConfiguration`, the orientation
    /// handler, and the preference restorer — onto a single FIFO off-main
    /// consumer. The `setPreferred*` round-trips to `mediaserverd` are
    /// synchronous and non-interruptible, so this is the only way to guarantee
    /// they never overlap (a cancel-on-set slot can't interrupt an in-flight
    /// XPC) and that cached-state write-backs land in request order.
    @ObservationIgnored let inputWriteQueue = SerialAsyncWorkQueue()
    typealias PersistedInputPreferences = AudioEnvironmentPreferenceStore.InputPreferences
    private var lifecycleRuntime: AudioEnvironmentLifecycleRuntime { .init(owner: self) }
    var sessionBootstrap: AudioSessionBootstrap { .init(owner: self) }
    var sessionController: AudioSessionController { .init(owner: self) }
    var inputPreferenceController: AudioInputPreferenceController { .init(owner: self) }
    private var inputPreferenceRestorer: AudioInputPreferenceRestorer { .init(owner: self) }
    var routeObserver: AudioRouteObserver { .init(owner: self) }

    /// Describes audio input configuration operations that require synchronous XPC
    /// round-trips to `mediaserverd`. Computed on MainActor (where cached state is
    /// readable) then executed off MainActor via ``executeInputConfiguration(_:session:)``
    /// to avoid run-loop hangs.
    struct InputConfigurationPlan {
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
    ///
    /// The work is submitted to ``inputWriteQueue`` so it is serialized FIFO
    /// against the setters and the restorer — the blocking XPC never overlaps
    /// another input-preference write.
    nonisolated static func executeInputConfiguration(
      _ plan: InputConfigurationPlan,
      session: AVAudioSession,
      queue: SerialAsyncWorkQueue,
    ) async throws(ManagerError) {
      let outcome: Result<Void, ManagerError>? = await queue.submit {
        () async -> Result<
          Void, ManagerError
        > in
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
          } catch {
            return Result<Void, ManagerError>.failure(.unexpected(ErrorContext(error)))
          }
        }

        if let input = plan.preferredInput, let source = plan.preferredSource {
          do {
            try input.set(preferredSource: source)
          } catch let error as AudioInput.PreferenceError {
            return Result<Void, ManagerError>.failure(.audioInput(error))
          } catch {
            return Result<Void, ManagerError>.failure(.unexpected(ErrorContext(error)))
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
      switch outcome {
      case .none:
        // Queue finished (manager teardown) — the write did not run; no-op.
        return
      case .some(.success):
        return
      case .some(.failure(let managerError)):
        throw managerError
      }
    }

    var isRestoringFromDefaults: Bool = false

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
    public internal(set) var isReady: Bool = false {
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
    public internal(set) var isRunning: Bool = false

    /// A Boolean value that indicates whether the audio session is currently active.
    public internal(set) var isAudioSessionActive: Bool = false
    var _orientation: AVAudioSession.StereoOrientation
    private var _selectedNumberOfChannels: ChannelCount
    private var _input: AudioInput?
    var _selectedSource: AudioSource?
    var _selectedSampleRate: SampleRate
    private var _availableInputs: [AudioInput]
    private var _availableSources: [AudioSource]
    var state: AudioEnvironmentState {
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
      SampleRate.common
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
      inputPreferenceController.setSampleRate(newValue, persistPreference: persistPreference)
    }

    /// The currently selected audio input.
    public var selectedInput: AudioInput? {
      get {
        _input ?? env.input ?? env.availableInputs.first
      }
      set {
        inputPreferenceController.setSelectedInput(newValue)
      }
    }

    /// The currently selected audio source.
    public var selectedSource: AudioSource? {
      get {
        _selectedSource
      }
      set {
        inputPreferenceController.setSelectedSource(newValue)
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
        sampleRate: SampleRate(sampleRate),
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

    public func applySourceConfiguration(
      source: AudioSource,
      channelCount: ChannelCount,
      polarPattern: PolarPattern? = nil,
      persistPreference: Bool = true,
    ) async throws(ManagerError) {
      try await inputPreferenceController.applySourceConfiguration(
        source: source,
        channelCount: channelCount,
        polarPattern: polarPattern,
        persistPreference: persistPreference,
      )
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
    /// Runs the audio environment manager.
    ///
    /// This method starts the audio session and begins monitoring for notifications such as route changes and interruptions.
    /// It will suspend without returning until its task is cancelled. On cancellation, it performs teardown and returns.
    ///
    /// - Throws: An error if the manager is already running.
    public func run() async throws(ManagerError) {
      try await lifecycleRuntime.run(sessionConfiguration: sessionConfiguration)
    }
  }

  extension AudioEnvironmentManager {
    @discardableResult
    @MainActor
    func updateAudioInputs(reason: String) async -> AudioDeviceChangeSummary? {
      await inputPreferenceController.updateAudioInputs(reason: reason)
    }

    // `nonisolated`: pure polar-pattern filtering with no main-actor state, so it
    // can serve as the `@Sendable` source filter when `AudioEnvironmentState` is
    // mirrored off the main actor (see `AudioEnvironmentState.mirroredOffMain`).
    nonisolated func filterSources(
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
    func dispatchInterruption(
      type: AudioInterruptionType,
      options: AudioInterruptionOptions?,
    ) async {
      await onInterruption?(type, options)
      await eventHub.dispatchInterruption(type: type, options: options)
    }

    @MainActor
    func dispatchRouteChange(_ event: AudioRouteChangeEvent) async {
      await onRouteChange?(event)
      await eventHub.dispatchRouteChange(event)
    }

    @MainActor
    func dispatchMediaServicesLost() async {
      await onMediaServicesLost?()
      await eventHub.dispatchMediaServicesLost()
    }

    @MainActor
    func dispatchMediaServicesReset() async {
      await onMediaServicesReset?()
      await eventHub.dispatchMediaServicesReset()
    }
  }

  extension AudioEnvironmentManager {
    @MainActor
    func restorePreferredInputAndConfigurationIfPossible(reason: String) async {
      await inputPreferenceRestorer.restorePreferredInputAndConfigurationIfPossible(reason: reason)
    }

    func stereoPreferenceRank(_ source: AudioSource) -> Int {
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

  extension Array where Element: Hashable {
    func removingDuplicates() -> Self {
      var set = Set<Element>()
      return filter {
        set.insert($0).inserted
      }
    }
  }

#endif
