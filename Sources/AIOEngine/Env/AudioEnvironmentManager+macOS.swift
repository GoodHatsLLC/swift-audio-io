#if os(macOS)
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

    public init(
      env: AudioEnvironment,
      errorManager: any ErrorManaging,
      defaults: UserDefaults = .standard
    ) {
      self.env = env
      self.errorManager = errorManager
      self.defaults = defaults
      self._useMeasurement = defaults.bool(forKey: StorageKey.useMeasurement)

      let defaultSource = AudioSource(
        id: "default-source",
        name: "Default Source",
        supportedPolarPatterns: [.omnidirectional, .stereo]
      )
      let defaultInput = AudioInput(
        id: "default-input",
        name: "Default Input",
        type: .builtInMic,
        channelCount: .stereo,
        availableSources: [defaultSource]
      )

      _availableInputs = [defaultInput]
      _selectedInput = defaultInput
      _availableSources = defaultInput.availableSources
      _selectedSource = defaultInput.selectedSource
      _sampleRate = .common(.sr48000)
      _channels = defaultInput.channelCount
    }

    private let env: AudioEnvironment
    private let errorManager: any ErrorManaging
    private let defaults: UserDefaults

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
        _selectedInput = newValue
        _availableSources = newValue?.availableSources ?? []
        if let selected = _selectedSource, !_availableSources.contains(selected) {
          _selectedSource = _availableSources.first
        } else if _selectedSource == nil {
          _selectedSource = _availableSources.first
        }

        _channels = newValue?.channelCount ?? .mono
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
      guard inputHasStereoSource else {
        throw .unsupportedOperation
      }
      _channels = .stereo
    }

    public func applyStereo(persistPreference: Bool) async throws(ManagerError) {
      _ = persistPreference
      try await applyStereo()
    }

    private var routeChangeSubscribers:
      [UUID: (@Sendable @MainActor (AudioRouteChangeEvent) async -> Void)] =
        [:]
    private var interruptionSubscribers:
      [UUID: (
        @Sendable @MainActor (AudioInterruptionType, AudioInterruptionOptions?) async -> Void
      )] =
        [:]
    private var mediaServicesLostSubscribers: [UUID: (@Sendable @MainActor () async -> Void)] = [:]
    private var mediaServicesResetSubscribers: [UUID: (@Sendable @MainActor () async -> Void)] = [:]

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
        @escaping @Sendable @MainActor (AudioInterruptionType, AudioInterruptionOptions?)
        async -> Void
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

    @MainActor
    public func readySignal() async throws(ManagerError) {
      if !isRunning {
        throw .notRunning
      }
    }

    public func setAudioSessionActive(_ active: Bool) throws(ManagerError) {
      guard isRunning else {
        return
      }
      isAudioSessionActive = active
    }

    public func run() async throws(ManagerError) {
      if isRunning {
        throw .alreadyRunning
      }
      isRunning = true
      isReady = true
    }
  }
#endif
