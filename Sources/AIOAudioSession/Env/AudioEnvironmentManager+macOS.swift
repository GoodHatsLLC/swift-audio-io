// © GoodHatsLLC

#if os(macOS)
  public import AIOContracts
  public import Foundation
  public import Observation
  public import Tools

  @MainActor
  @Observable
  public final class AudioEnvironmentManager: AudioSessionDelegate {
    public enum ManagerError: AudioError {
      case alreadyRunning
      case notRunning
      case unsupportedOperation

      public var description: String {
        switch self {
        case .alreadyRunning:
          "AudioEnvironmentManager is already running"
        case .notRunning:
          "AudioEnvironmentManager is not running"
        case .unsupportedOperation:
          "Requested audio operation is unsupported on this platform"
        }
      }
    }

    @MainActor
    public static func prepareAudioSessionCategoryForAppLaunch() {}

    public convenience init(
      env: AudioEnvironment,
      errorManager: any ErrorManaging,
      defaults: UserDefaults = .standard,
    ) {
      self.init(
        env: env,
        errorManager: errorManager,
        defaults: defaults,
        platformAudioBackend: PlatformAudioBackendFactory.makeDefault(),
      )
    }

    init(
      env: AudioEnvironment,
      errorManager: any ErrorManaging,
      defaults: UserDefaults,
      platformAudioBackend: any PlatformAudioBackend,
    ) {
      self.env = env
      self.errorManager = errorManager
      self.defaults = defaults
      self.platformAudioBackend = platformAudioBackend
      _useMeasurement = defaults.bool(forKey: StorageKey.useMeasurement)
      _availableInputs = []
      _selectedInput = nil
      _availableSources = []
      _selectedSource = nil
      _sampleRate = .common(.sr48000)
      _channels = .mono
    }

    private let env: AudioEnvironment
    private let errorManager: any ErrorManaging
    private let defaults: UserDefaults
    private let platformAudioBackend: any PlatformAudioBackend
    private var sessionController: AudioSessionController { .init(owner: self) }
    private var routeObserver: AudioRouteObserver { .init(owner: self) }
    private var backendRouteTask: Task<Void, Never>?

    private enum StorageKey {
      static let useMeasurement = "aio.audio_env.use_measurement"
    }

    public var sessionConfiguration: AudioSessionConfiguration = .recordingConfiguration

    public private(set) var isRunning = false
    public private(set) var isReady = false
    public private(set) var isAudioSessionActive = false

    private var _selectedInput: AudioInput?
    private var _availableInputs: [AudioInput]
    private var _selectedSource: AudioSource?
    private var _availableSources: [AudioSource]
    private var _sampleRate: SampleRate
    private var _channels: ChannelCount
    private var _useMeasurement: Bool

    public var onRequestAudioSessionActive: (@MainActor (Bool) -> Void)?

    public var audioSessionActive: Bool {
      get { isAudioSessionActive }
      set {
        guard newValue != isAudioSessionActive else { return }
        if let handler = onRequestAudioSessionActive {
          handler(newValue)
          return
        }
        do {
          try setAudioSessionActive(newValue)
        } catch {
          errorManager.enqueue(error)
        }
      }
    }

    public var shouldAutoSelectStereoWhenAvailable: Bool {
      true
    }

    public var useMeasurement: Bool {
      get { _useMeasurement }
      set {
        _useMeasurement = newValue
        defaults.set(newValue, forKey: StorageKey.useMeasurement)
      }
    }

    public var channels: ChannelCount {
      _channels
    }

    public var availableSources: [AudioSource] {
      _availableSources
    }

    public var availableInputs: [AudioInput] {
      _availableInputs
    }

    public var likelySupportedSampleRates: [SampleRate] {
      Array(Set(SampleRate.commonCases + [_sampleRate])).sorted()
    }

    public var sampleRate: SampleRate {
      get { _sampleRate }
      set { setSampleRate(newValue, persistPreference: true) }
    }

    public func setSampleRate(_ newValue: SampleRate, persistPreference: Bool = true) {
      _ = persistPreference
      _sampleRate = newValue
    }

    public var selectedInput: AudioInput? {
      get { _selectedInput }
      set {
        let requestedChannelPreference = _channels
        _selectedInput = newValue
        _availableSources = newValue?.availableSources ?? []
        if let selected = _selectedSource, !_availableSources.contains(selected) {
          _selectedSource = _availableSources.first
        } else if _selectedSource == nil {
          _selectedSource = _availableSources.first
        }

        let maxSupportedChannels = newValue?.channelCount ?? .mono
        if requestedChannelPreference == .stereo, maxSupportedChannels == .stereo {
          _channels = .stereo
        } else {
          _channels = .mono
        }
      }
    }

    public var selectedSource: AudioSource? {
      get { _selectedSource }
      set {
        if let newValue, !_availableSources.contains(newValue) {
          return
        }
        _selectedSource = newValue
      }
    }

    public var inputHasStereoSource: Bool {
      _availableSources.contains { $0.hasStereo }
    }

    public var availableChannelCountsForSelectedSource: [ChannelCount] {
      guard let selectedSource = _selectedSource else {
        return inputHasStereoSource ? [.mono, .stereo] : [.mono]
      }
      return selectedSource.hasStereo ? [.mono, .stereo] : [.mono]
    }

    public var isConfiguredForStereo: Bool {
      _channels == .stereo
    }

    public func applyMono() async throws(ManagerError) {
      _channels = .mono
    }

    public func applyMono(persistPreference: Bool) async throws(ManagerError) {
      _ = persistPreference
      try await applyMono()
    }

    public func applyStereo() async throws(ManagerError) {
      guard selectedInput?.channelCount == .stereo else {
        throw .unsupportedOperation
      }
      _channels = .stereo
    }

    public func applyStereo(persistPreference: Bool) async throws(ManagerError) {
      _ = persistPreference
      try await applyStereo()
    }

    public func applySourceConfiguration(
      source: AudioSource,
      channelCount: ChannelCount,
      polarPattern: PolarPattern? = nil,
      persistPreference: Bool = true,
    ) async throws(ManagerError) {
      _ = persistPreference
      guard _availableSources.contains(source) else {
        throw .unsupportedOperation
      }
      if let polarPattern, !source.supportedPolarPatterns.contains(polarPattern) {
        throw .unsupportedOperation
      }

      _selectedSource = source
      if channelCount == .stereo {
        guard source.hasStereo else {
          throw .unsupportedOperation
        }
        try await applyStereo()
      } else {
        try await applyMono()
      }
    }

    private let eventHub = AudioEnvironmentEventHub()

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

    @MainActor
    public func readySignal() async throws(ManagerError) {
      if !isRunning {
        throw .notRunning
      }
    }

    public func setAudioSessionActive(_ active: Bool) throws(ManagerError) {
      try sessionController.setAudioSessionActive(active)
    }

    public func run() async throws(ManagerError) {
      if isRunning {
        throw .alreadyRunning
      }
      isRunning = true
      await refreshInputsFromPlatform()
      isReady = true

      backendRouteTask?.cancel()
      backendRouteTask = routeObserver.makeRouteTask()

      // Keep parity with iOS semantics: `run()` represents a long-lived manager loop
      // and only returns after cancellation.
      await withCancellationOperation {
        backendRouteTask?.cancel()
        backendRouteTask = nil
        isAudioSessionActive = false
        isReady = false
        isRunning = false
      }
    }

    private func refreshInputsFromPlatform() async {
      let descriptors = await platformAudioBackend.availableInputs()
      let inputs = descriptors.map { descriptor in
        makeAudioInput(from: descriptor)
      }

      _availableInputs = inputs
      let defaultInputID = descriptors.first(where: \.isDefault)?.id
      let selected =
        inputs.first(where: { $0.id == _selectedInput?.id })
        ?? inputs.first(where: { $0.id == defaultInputID })
        ?? inputs.first
      selectedInput = selected
    }

    private func makeAudioInput(from descriptor: PlatformAudioInputDescriptor) -> AudioInput {
      let supportsStereo = descriptor.channelCount >= 2
      let sourcePatterns: [PolarPattern] =
        supportsStereo ? [.omnidirectional, .stereo] : [.omnidirectional]
      let defaultSource = AudioSource(
        id: "\(descriptor.id)-source",
        name: descriptor.name,
        supportedPolarPatterns: sourcePatterns,
      )
      return AudioInput(
        id: descriptor.id,
        name: descriptor.name,
        type: .unknown,
        channelCount: supportsStereo ? .stereo : .mono,
        availableSources: [defaultSource],
      )
    }

    private func notifyRouteChangeSubscribers() async {
      let event = AudioRouteChangeEvent(userMessage: "Audio route changed")
      await eventHub.dispatchRouteChange(event)
    }
  }

  extension AudioEnvironmentManager {
    private struct AudioSessionController {
      let owner: AudioEnvironmentManager

      @MainActor
      func setAudioSessionActive(_ active: Bool) throws(ManagerError) {
        guard owner.isRunning else {
          return
        }
        owner.isAudioSessionActive = active
      }
    }

    private struct AudioRouteObserver {
      let owner: AudioEnvironmentManager

      @MainActor
      func makeRouteTask() -> Task<Void, Never> {
        let backend = owner.platformAudioBackend
        return Task { @MainActor [weak owner] in
          guard let owner else { return }
          for await _ in backend.routeChanges() {
            await owner.refreshInputsFromPlatform()
            await owner.notifyRouteChangeSubscribers()
          }
        }
      }
    }
  }
#endif
