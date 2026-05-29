// © GoodHatsLLC

#if canImport(AVFoundation)
  public import AIOAudioSession
  public import AIOContracts
  public import AIOEngineCore

  // The following modules stay on `@_exported import` until the relevant
  // member surface is moved into the AudioIO target:
  //
  // - AIOPlayback, AIORecording contribute `public` extension methods on
  //   `AIOEngine` (defined in AIOEngineCore). Swift has no typealias-based
  //   re-export for extension methods.
  // - AIOVisualization, AIOMicHealth, AudioSignals contribute `public`
  //   instance methods, initializers, and static members that consumers
  //   call directly. Swift 6's `MemberImportVisibility` upcoming feature
  //   prevents callers from reaching those members through a transitive
  //   `public import`, so the consuming targets would need to add direct
  //   `import` lines for each of those source modules; instead we keep
  //   `@_exported` here.
  //
  // Asymmetry note: AIOAudioSession is on `public import` above despite
  // having `public` instance methods on `AudioEnvironmentManager` that
  // AppLibrary calls directly. This works today because AppLibrary's
  // hot call sites use the `AudioEnvironmentDriving` / `AudioEnvironment-
  // Configuring` protocol contracts defined inside the AudioIO target
  // itself (see `Contracts/RuntimeDriving.swift`), so MemberImportVisibility
  // never trips. Future direct-call hot paths might force AIOAudioSession
  // back onto `@_exported import`. Migrate behind a protocol contract first.
  @_exported import AIOMicHealth
  @_exported import AIOPlayback
  // AIORecording is re-exported with @_spi(Advanced) so that the
  // reconciliation-mode start API (setDesiredRecordingState /
  // startRecordingWithReconciliation) — gated behind @_spi(Advanced) on the
  // concrete AIOEngine and on the RecordingDriving protocol — can be reached
  // from `@_spi(Advanced) import AudioIO` consumers. Mainstream callers
  // see only the canonical startRecording(configuration:) entry point.
  @_spi(Advanced) @_exported import AIORecording
  @_exported import AIOVisualization
  @_exported import AudioSignals

  // MARK: - AIOAudioSession re-exports

  public typealias AudioChannel = AIOAudioSession.AudioChannel
  public typealias AudioEnvironment = AIOAudioSession.AudioEnvironment
  public typealias AudioEnvironmentManager = AIOAudioSession.AudioEnvironmentManager
  public typealias AudioInput = AIOAudioSession.AudioInput
  public typealias AudioInterruptionOptions = AIOAudioSession.AudioInterruptionOptions
  public typealias AudioInterruptionType = AIOAudioSession.AudioInterruptionType
  public typealias AudioRouteChangeEvent = AIOAudioSession.AudioRouteChangeEvent
  public typealias AudioSessionConfiguration = AIOAudioSession.AudioSessionConfiguration
  public typealias AudioSource = AIOAudioSession.AudioSource
  #if os(iOS)
    public typealias AudioPortSnapshot = AIOAudioSession.AudioPortSnapshot
    public typealias AudioRouteSnapshot = AIOAudioSession.AudioRouteSnapshot
    public typealias AudioSessionSnapshot = AIOAudioSession.AudioSessionSnapshot
  #endif
  public typealias AnyErrorManager = AIOAudioSession.AnyErrorManager
  public typealias AudioIOError = AIOAudioSession.AudioIOError
  public typealias BitDepth = AIOAudioSession.BitDepth
  public typealias ChannelCount = AIOAudioSession.ChannelCount
  public typealias EncodingQuality = AIOAudioSession.EncodingQuality
  public typealias ErrorManager = AIOAudioSession.ErrorManager
  public typealias ErrorManaging = AIOAudioSession.ErrorManaging
  public typealias FileFormat = AIOAudioSession.FileFormat
  public typealias InputConfiguration = AIOAudioSession.InputConfiguration
  // `MockErrorManager` is `#if DEBUG`-only in AIOAudioSession, so the re-export
  // must carry the same gate — otherwise release/archive builds fail to resolve
  // a type that was never compiled into the module.
  #if DEBUG
    public typealias MockErrorManager = AIOAudioSession.MockErrorManager
  #endif
  #if canImport(UIKit) && !os(macOS)
    public typealias OrientationObserver = AIOAudioSession.OrientationObserver
  #endif
  public typealias OutputConfiguration = AIOAudioSession.OutputConfiguration
  public typealias OutputConfigurationManager = AIOAudioSession.OutputConfigurationManager
  public typealias PlaybackError = AIOAudioSession.PlaybackError
  public typealias PolarPattern = AIOAudioSession.PolarPattern
  public typealias RecordingConfiguration = AIOAudioSession.RecordingConfiguration
  public typealias RecordingError = AIOAudioSession.RecordingError
  public typealias RecordingFilename = AIOAudioSession.RecordingFilename
  public typealias ReconciliationConfiguration = AIOAudioSession.ReconciliationConfiguration
  public typealias ReportedError = AIOAudioSession.ReportedError
  public typealias Reporter = AIOAudioSession.Reporter
  public typealias SampleRate = AIOAudioSession.SampleRate
  public typealias SessionError = AIOAudioSession.SessionError
  public typealias SourceLocation = AIOAudioSession.SourceLocation
  public typealias TypeDescribable = AIOAudioSession.TypeDescribable

  // MARK: - AIOContracts re-exports

  public typealias AudioSessionDelegate = AIOContracts.AudioSessionDelegate
  public typealias BufferEmitter = AIOContracts.BufferEmitter
  public typealias BufferReceiver = AIOContracts.BufferReceiver
  public typealias BufferReceiverToken = AIOContracts.BufferReceiverToken
  public typealias BufferTiming = AIOContracts.BufferTiming

  // MARK: - AIOEngineCore re-exports

  public typealias AIOEngine = AIOEngineCore.AIOEngine
  public typealias AudioIOEvent = AIOEngineCore.AudioIOEvent
  public typealias VerboseError = AIOEngineCore.VerboseError

  // MARK: - AIOMicHealth re-exports

  public typealias MicHealthInputs = AIOMicHealth.MicHealthInputs
  public typealias MicHealthMonitor = AIOMicHealth.MicHealthMonitor
  public typealias MicHealthReason = AIOMicHealth.MicHealthReason
  public typealias MicHealthReasonKey = AIOMicHealth.MicHealthReasonKey
  public typealias MicHealthState = AIOMicHealth.MicHealthState
  public typealias MicHealthThresholds = AIOMicHealth.MicHealthThresholds
  public typealias PendingTrackEvent = AIOMicHealth.PendingTrackEvent
  public typealias PendingTrackEventKind = AIOMicHealth.PendingTrackEventKind

  // MARK: - AIOVisualization re-exports

  public typealias AnalysisWork = AIOVisualization.AnalysisWork
  public typealias AudioVisualizationEngine = AIOVisualization.AudioVisualizationEngine
  public typealias FrequencyDomainWork = AIOVisualization.FrequencyDomainWork
  public typealias LODWork = AIOVisualization.LODWork
  public typealias VisualizationDriving = AIOVisualization.VisualizationDriving
  public typealias VisualizationEvent = AIOVisualization.VisualizationEvent
  public typealias VisualizationEventMask = AIOVisualization.VisualizationEventMask
  public typealias VisualizationRequest = AIOVisualization.VisualizationRequest
  public typealias VisualizationSink = AIOVisualization.VisualizationSink
  public typealias VisualizationSubscription = AIOVisualization.VisualizationSubscription
  public typealias VisualizationWork = AIOVisualization.VisualizationWork

  // MARK: - AudioSignals re-exports

  public typealias AmplitudeAnalyzer = AudioSignals.AmplitudeAnalyzer
  public typealias AmplitudeData = AudioSignals.AmplitudeData
  public typealias BandLODData = AudioSignals.BandLODData
  public typealias BeatDetectionConfiguration = AudioSignals.BeatDetectionConfiguration
  public typealias BeatDetector = AudioSignals.BeatDetector
  public typealias BeatInfo = AudioSignals.BeatInfo
  public typealias CrossoverMode = AudioSignals.CrossoverMode
  public typealias FrequencyAnalyzer = AudioSignals.FrequencyAnalyzer
  public typealias FrequencyAnalyzerError = AudioSignals.FrequencyAnalyzerError
  public typealias FrequencyBucket = AudioSignals.FrequencyBucket
  public typealias FrequencyBucketMode = AudioSignals.FrequencyBucketMode
  public typealias FrequencyBucketer = AudioSignals.FrequencyBucketer
  public typealias FrequencyDomainData = AudioSignals.FrequencyDomainData
  public typealias FrequencyWeighting = AudioSignals.FrequencyWeighting
  public typealias LODChannel = AudioSignals.LODChannel
  public typealias LODSnapshot = AudioSignals.LODSnapshot
  public typealias LODSnapshotRef = AudioSignals.LODSnapshotRef
  public typealias MultiBandLODConfiguration = AudioSignals.MultiBandLODConfiguration
  public typealias MultiBandLODProcessor = AudioSignals.MultiBandLODProcessor
  public typealias MultiBandLODSnapshot = AudioSignals.MultiBandLODSnapshot
  // NOTE: `OfflineLODExtractor` and `OfflineLODResult` are intentionally
  // NOT re-exported here. Any caller in a target that combines
  // `import AudioIO` (default `internal` access) with
  // `package import AudioSignals` is at risk: introducing a typealias
  // makes Swift resolve those references through the `internal`-imported
  // typealias path and triggers an access-level mismatch when the
  // reference appears in a `package` API surface (e.g., a `package init`
  // parameter). The current known hazard sites in AppLibrary are
  // `Waveforms/Metal/MetalClipWaveformThumbnailView.swift` and the
  // `Waveforms/Metal/WaveformSnapshotLoader.swift` neighborhood. The
  // underlying types remain reachable via the `@_exported import
  // AudioSignals` line above.
  public typealias SnapshotProvider = AudioSignals.SnapshotProvider
  public typealias SpectrumData = AudioSignals.SpectrumData
  public typealias StandardBands = AudioSignals.StandardBands
  public typealias TimeDomainData = AudioSignals.TimeDomainData
  public typealias VisualizationRateDefaults = AudioSignals.VisualizationRateDefaults
#endif
