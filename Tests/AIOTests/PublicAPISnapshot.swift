// © GoodHatsLLC

import AudioIO
import Testing

// Public-API snapshot fixture.
//
// Each test below references the curated `public typealias` declarations
// from `Sources/AudioIO/Exports.swift`. The compile itself is the
// assertion: if a future change drops one of these symbols from the
// `import AudioIO` surface, this file fails to build, which is exactly
// the canary we want.
//
// Adding a symbol to AudioIO's curated surface should be paired with a
// new line here so the surface is pinned. Removing a symbol must be a
// deliberate decision visible in this file.

@Test("Public API snapshot — AIOAudioSession re-exports compile via AudioIO")
func publicAPISnapshot_AIOAudioSession() throws {
  _ = AudioChannel.self
  _ = AudioEnvironment.self
  _ = AudioEnvironmentManager.self
  _ = AudioInput.self
  _ = AudioInterruptionOptions.self
  _ = AudioInterruptionType.self
  _ = AudioRouteChangeEvent.self
  _ = AudioSessionConfiguration.self
  _ = AudioSource.self
  #if os(iOS)
    _ = AudioPortSnapshot.self
    _ = AudioRouteSnapshot.self
    _ = AudioSessionSnapshot.self
  #endif
  _ = AnyErrorManager.self
  _ = BitDepth.self
  _ = ChannelCount.self
  _ = EncodingQuality.self
  _ = ErrorManager.self
  _ = (any ErrorManaging).self
  _ = FileFormat.self
  _ = InputConfiguration.self
  _ = MockErrorManager.self
  #if canImport(UIKit) && !os(macOS)
    _ = OrientationObserver.self
  #endif
  _ = OutputConfiguration.self
  _ = OutputConfigurationManager.self
  _ = PolarPattern.self
  _ = RecordingConfiguration.self
  _ = RecordingFilename.self
  _ = ReconciliationConfiguration.self
  _ = ReportedError.self
  _ = Reporter<ReportedError>.self
  _ = SampleRate.self
  _ = SourceLocation.self
  _ = (any TypeDescribable).self
}

@Test("Public API snapshot — AIOContracts re-exports compile via AudioIO")
func publicAPISnapshot_AIOContracts() throws {
  _ = (any AudioSessionDelegate).self
  _ = (any BufferEmitter<Float>).self
  _ = (any BufferReceiver<Float>).self
  _ = BufferReceiverToken.self
  _ = BufferTiming.self
}

@Test("Public API snapshot — AIOEngineCore re-exports compile via AudioIO")
func publicAPISnapshot_AIOEngineCore() throws {
  _ = AIOEngine.self
  _ = VerboseError.self
}

@Test("Public API snapshot — AIOMicHealth re-exports compile via AudioIO")
func publicAPISnapshot_AIOMicHealth() throws {
  _ = MicHealthInputs.self
  _ = MicHealthMonitor.self
  _ = MicHealthReason.self
  _ = MicHealthReasonKey.self
  _ = MicHealthState.self
  _ = MicHealthThresholds.self
  _ = PendingTrackEvent.self
  _ = PendingTrackEventKind.self
}

@Test("Public API snapshot — AIOVisualization re-exports compile via AudioIO")
func publicAPISnapshot_AIOVisualization() throws {
  _ = AudioVisualizationEngine.self
  _ = (any VisualizationDriving).self
  _ = VisualizationEvent.self
  _ = VisualizationEventMask.self
  _ = VisualizationRequest.self
  _ = (any VisualizationSink).self
  _ = VisualizationSubscription.self
}

@Test("Public API snapshot — AudioSignals re-exports compile via AudioIO")
func publicAPISnapshot_AudioSignals() throws {
  _ = AmplitudeAnalyzer.self
  _ = AmplitudeData.self
  _ = BandLODData.self
  _ = BeatDetectionConfiguration.self
  _ = BeatDetector.self
  _ = BeatInfo.self
  _ = CrossoverMode.self
  _ = FrequencyAnalyzer.self
  _ = FrequencyAnalyzerError.self
  _ = FrequencyBucket.self
  _ = FrequencyBucketMode.self
  _ = FrequencyBucketer.self
  _ = FrequencyDomainData.self
  _ = FrequencyDomainWork.self
  _ = FrequencyWeighting.self
  _ = LODChannel.self
  _ = (any LODSnapshot).self
  _ = LODSnapshotRef.self
  _ = LODWork.self
  _ = AnalysisWork.self
  _ = MultiBandLODConfiguration.self
  // `MultiBandLODProcessor` is `@unsafe`; the `unsafe` keyword is required
  // at reference sites under `SWIFT_STRICT_MEMORY_SAFETY`. Don't "clean
  // up" by removing it.
  _ = unsafe MultiBandLODProcessor.self
  // `LODGenerationError` is a nested enum inside `MultiBandLODProcessor`,
  // used in `throws(...)` clauses on `OfflineLODExtractor.extract(...)`.
  // Pinned here so a rename or access-level drop fails the snapshot.
  _ = MultiBandLODProcessor.LODGenerationError.self
  _ = MultiBandLODSnapshot.self
  _ = (any SnapshotProvider).self
  _ = SpectrumData.self
  _ = StandardBands.self
  _ = TimeDomainData.self
  _ = VisualizationRateDefaults.self
  _ = VisualizationWork.self
}
