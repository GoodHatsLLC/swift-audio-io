// © GoodHatsLLC

#if canImport(AVFAudio)
  import AIOContracts
  import AIOSupport
  import Atomics
  import AudioSignals
  import AVFAudio
  import Foundation
  import os
  import Tools

  private let processorLog = SystemLog.make()

  @safe final class VisualizationProcessor {
    struct Callbacks {
      let onAnalysisFrame: @Sendable (AnalysisFrame) -> Void
      let onLatestBufferTiming: @Sendable (BufferTiming) -> Void
      let onLODSnapshot: @Sendable () -> Void
      let onFrequencyLabelsChanged: @Sendable ([(frequency: Float, label: String)]) -> Void
    }

    struct AnalysisFrame: Sendable {
      let timeDomain: TimeDomainData?
      let frequencyDomain: FrequencyDomainData?
      let spectrumPeakHold: [Float]
      let beat: BeatInfo?
    }

    private struct AnalysisFlags: OptionSet {
      let rawValue: Int

      static let timeDomain = AnalysisFlags(rawValue: 1 << 0)
      static let frequencyDomain = AnalysisFlags(rawValue: 1 << 1)
      static let beat = AnalysisFlags(rawValue: 1 << 2)
    }

    private struct AnalysisConfig: Equatable {
      var timeDomain: AmplitudeAnalyzer.Configuration?
      var frequencyDomain: FrequencyDomainWork?
      var beatDetection: BeatDetectionConfiguration?
    }

    @safe private final class AnalysisPipeline {
      let amplitudeAnalyzer: AmplitudeAnalyzer?
      let frequencyAnalyzer: FrequencyAnalyzer?
      let frequencyBucketer: FrequencyBucketer?
      let beatDetector: BeatDetector?
      let frequencySampleCount: Int
      let peakHoldDecayRate: Float
      let ringBuffer: SPSCRingBuffer<Float>
      let maxVisualizationSamples: Int
      var readScratchBuffer: [Float]

      init(config: AnalysisConfig, sampleRate: Double) {
        if let amplitudeConfig = config.timeDomain {
          amplitudeAnalyzer = AmplitudeAnalyzer(configuration: amplitudeConfig)
        } else {
          amplitudeAnalyzer = nil
        }

        var builtFrequencyAnalyzer: FrequencyAnalyzer?
        var frequencySampleCount = 0
        var frequencyBucketer: FrequencyBucketer?
        var peakHoldDecayRate: Float = 0.015

        if let frequencyWork = config.frequencyDomain {
          let frequencyConfig = frequencyWork.configuration
          frequencySampleCount = frequencyConfig.fftSize
          do {
            builtFrequencyAnalyzer = try FrequencyAnalyzer(configuration: frequencyConfig)
          } catch {
            processorLog.error(
              "Failed to create FrequencyAnalyzer: \(error.localizedDescription, privacy: .public)",
            )
            frequencySampleCount = 0
          }
          frequencyBucketer = FrequencyBucketer(
            mode: frequencyWork.bucketMode,
            sampleRate: Float(sampleRate),
            peakHoldDecayRate: frequencyWork.peakHoldDecayRate,
            weighting: frequencyWork.weighting,
          )
          peakHoldDecayRate = frequencyWork.peakHoldDecayRate
        }

        frequencyAnalyzer = builtFrequencyAnalyzer
        self.frequencySampleCount = frequencySampleCount
        self.frequencyBucketer = frequencyBucketer
        self.peakHoldDecayRate = peakHoldDecayRate

        if let beatConfig = config.beatDetection {
          beatDetector = BeatDetector(configuration: beatConfig)
        } else {
          beatDetector = nil
        }

        let maxSamples = max(config.timeDomain?.windowSize ?? 0, frequencySampleCount)
        let resolvedMaxSamples = max(maxSamples, 1)
        let ringCapacity = max(resolvedMaxSamples * 4, 1024)
        maxVisualizationSamples = resolvedMaxSamples
        ringBuffer = SPSCRingBuffer<Float>(capacity: ringCapacity)
        readScratchBuffer = Array(repeating: 0.0, count: resolvedMaxSamples)
      }
    }

    private let configuration: AudioVisualizationEngine.Configuration
    private let callbacks: Callbacks

    private let analysisTicker = VisualizationDispatchTicker(
      label: "audio-visualization",
      qos: .userInteractive,
    )
    private let lodPublishTicker = VisualizationDispatchTicker(
      label: "audio-visualization.lod-publish",
      qos: .userInteractive,
    )

    private let isActiveAtomic = ManagedAtomic<Bool>(false)
    private let analysisEnabledAtomic = ManagedAtomic<Bool>(false)
    private let lodEnabledAtomic = ManagedAtomic<Bool>(false)
    private let analysisFlagsAtomic = ManagedAtomic<Int>(0)
    private let fallbackSampleTimeAtomic = ManagedAtomic<Int64>(0)
    private let latestEndSampleTimeAtomic = ManagedAtomic<Int64>(0)
    private let latestSampleRateBitsAtomic: ManagedAtomic<UInt64>
    private let lastBeatUpdateEndSampleTimeAtomic = ManagedAtomic<Int64>(0)

    private var lodProcessor: MultiBandLODProcessor?
    private var lodConfig: MultiBandLODConfiguration?
    private var analysisConfig: AnalysisConfig?
    private var analysisPipeline: AnalysisPipeline?
    private var analysisUpdateRateHz: Double?
    private var lodPublishRateHz: Double?
    private var spectrumPeakHold: [Float] = []

    init(
      configuration: AudioVisualizationEngine.Configuration,
      callbacks: Callbacks,
    ) {
      self.configuration = configuration
      self.callbacks = callbacks
      latestSampleRateBitsAtomic = ManagedAtomic(configuration.sampleRate.bitPattern)
    }

    var currentTimeSeconds: TimeInterval {
      let endSampleTime = latestEndSampleTimeAtomic.load(ordering: .relaxed)
      let sampleRate = currentSampleRate
      return Double(endSampleTime) / max(sampleRate, 1)
    }

    var currentSampleRate: Double {
      let bits = latestSampleRateBitsAtomic.load(ordering: .relaxed)
      let value = Double(bitPattern: bits)
      return value > 0 ? value : configuration.sampleRate
    }

    var multiBandLOD: MultiBandLODSnapshot? {
      unsafe lodProcessor?.snapshot()
    }

    func withCurrentLODSnapshotRef<R>(_ body: (LODSnapshotRef) -> R) -> R? {
      guard let processor = unsafe lodProcessor else { return nil }
      return unsafe processor.withCurrentLODSnapshotRef(body)
    }

    var isMultiBandLODEnabled: Bool {
      unsafe lodProcessor != nil
    }

    @discardableResult
    func setActive(_ isActive: Bool) -> Bool {
      let wasActive = isActiveAtomic.exchange(isActive, ordering: .relaxed)
      guard wasActive != isActive else { return false }

      if isActive {
        updateAnalysisCadenceIfNeeded()
        updateLodPublishCadenceIfNeeded()
      } else {
        analysisTicker.cancel()
        lodPublishTicker.cancel()
      }

      return true
    }

    func apply(work: VisualizationWork) {
      let resolvedLodWork = work.lod
      let wantsLod = resolvedLodWork != nil
      lodPublishRateHz = resolvedLodWork?.publishRateHz

      if let lodWork = resolvedLodWork, wantsLod {
        let resolvedConfig = normalizedLODConfig(lodWork.configuration)
        if lodConfig != resolvedConfig {
          lodEnabledAtomic.store(false, ordering: .relaxed)
          unsafe lodProcessor = unsafe MultiBandLODProcessor(configuration: resolvedConfig)
          lodConfig = resolvedConfig
        }
        lodEnabledAtomic.store(true, ordering: .relaxed)
        processorLog.info(
          "Visualization LOD: publishRate=\(lodWork.publishRateHz, privacy: .public)Hz snapshotSwapInterval=\(resolvedConfig.snapshotSwapInterval, privacy: .public) lodRatio=\(resolvedConfig.lodRatio, privacy: .public)",
        )
      } else {
        lodEnabledAtomic.store(false, ordering: .relaxed)
        unsafe lodProcessor = nil
        lodConfig = nil
      }

      var flags: AnalysisFlags = []
      if let analysisWork = work.analysis {
        if analysisWork.timeDomain != nil || analysisWork.beatDetection != nil {
          flags.insert(.timeDomain)
        }
        if analysisWork.frequencyDomain != nil {
          flags.insert(.frequencyDomain)
        }
        if analysisWork.beatDetection != nil {
          flags.insert(.beat)
        }
      }

      analysisFlagsAtomic.store(flags.rawValue, ordering: .relaxed)
      analysisEnabledAtomic.store(!flags.isEmpty, ordering: .relaxed)
      analysisUpdateRateHz =
        flags.isEmpty
        ? nil
        : (work.analysis?.updateRateHz ?? configuration.analysisUpdateRateHz)

      configureAnalysisPipelineIfNeeded(analysisWork: work.analysis, flags: flags)
      updateAnalysisCadenceIfNeeded()
      updateLodPublishCadenceIfNeeded()
    }

    func reset() {
      _ = setActive(false)

      spectrumPeakHold.removeAll()
      analysisPipeline?.frequencyBucketer?.resetPeakHold()
      analysisPipeline?.beatDetector?.reset()
      analysisPipeline?.ringBuffer.clear()
      analysisPipeline = nil
      analysisConfig = nil
      analysisUpdateRateHz = nil
      lodPublishRateHz = nil
      callbacks.onFrequencyLabelsChanged([])

      fallbackSampleTimeAtomic.store(0, ordering: .relaxed)
      latestEndSampleTimeAtomic.store(0, ordering: .relaxed)
      latestSampleRateBitsAtomic.store(configuration.sampleRate.bitPattern, ordering: .relaxed)
      lastBeatUpdateEndSampleTimeAtomic.store(0, ordering: .relaxed)

      analysisEnabledAtomic.store(false, ordering: .relaxed)
      lodEnabledAtomic.store(false, ordering: .relaxed)
      analysisFlagsAtomic.store(0, ordering: .relaxed)

      unsafe lodProcessor?.reset()
    }

    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
      guard isActiveAtomic.load(ordering: .relaxed),
        let floatData = unsafe buffer.floatChannelData?[0]
      else { return }

      let bufferPointer = unsafe UnsafeBufferPointer(
        start: floatData,
        count: Int(buffer.frameLength),
      )
      unsafe processBuffer(bufferPointer)
    }

    func processBuffer(_ data: UnsafeBufferPointer<Float>) {
      let startSampleTime = fallbackSampleTimeAtomic.load(ordering: .relaxed)
      fallbackSampleTimeAtomic.wrappingIncrement(by: Int64(data.count), ordering: .relaxed)
      let timing = BufferTiming(
        sampleTime: startSampleTime,
        sampleRate: configuration.sampleRate,
      )
      unsafe processBuffer(data, timing: timing)
    }

    func processBuffer(
      _ data: UnsafeBufferPointer<Float>,
      timing: BufferTiming,
    ) {
      latestEndSampleTimeAtomic.store(
        timing.sampleTime + Int64(data.count),
        ordering: .relaxed,
      )
      latestSampleRateBitsAtomic.store(timing.sampleRate.bitPattern, ordering: .relaxed)
      callbacks.onLatestBufferTiming(timing)

      guard isActiveAtomic.load(ordering: .relaxed) else { return }
      if analysisEnabledAtomic.load(ordering: .relaxed) {
        unsafe updateAudioBuffer(data)
      }

      if lodEnabledAtomic.load(ordering: .relaxed) {
        unsafe lodProcessor?.process(data)
      }
    }

    private func normalizedLODConfig(_ config: MultiBandLODConfiguration)
      -> MultiBandLODConfiguration
    {
      let sampleRate = max(Int(configuration.sampleRate.rounded()), 1)
      return MultiBandLODConfiguration(
        bandCount: config.bandCount,
        lodRatio: config.lodRatio,
        bufferSeconds: config.bufferSeconds,
        sampleRate: sampleRate,
        crossoverMode: config.crossoverMode,
        snapshotSwapInterval: config.snapshotSwapInterval,
        rawBufferLengthOverride: config.rawBufferLengthOverride,
      )
    }

    private func normalizedFrequencyWork(_ work: FrequencyDomainWork) -> FrequencyDomainWork {
      let config = work.configuration
      let sampleRate = configuration.sampleRate
      guard config.sampleRate != sampleRate else { return work }
      let adjusted = FrequencyAnalyzer.Configuration(
        fftSize: config.fftSize,
        spectrumSize: config.spectrumSize,
        sampleRate: sampleRate,
        smoothingFactor: config.smoothingFactor,
        noiseFloor: config.noiseFloor,
        windowType: config.windowType,
      )
      return FrequencyDomainWork(
        configuration: adjusted,
        bucketMode: work.bucketMode,
        peakHoldDecayRate: work.peakHoldDecayRate,
        weighting: work.weighting,
      )
    }

    private func configureAnalysisPipelineIfNeeded(
      analysisWork: AnalysisWork?,
      flags: AnalysisFlags,
    ) {
      guard !flags.isEmpty else {
        callbacks.onFrequencyLabelsChanged([])
        return
      }

      var resolvedTimeDomain = analysisWork?.timeDomain
      if (flags.contains(.timeDomain) || flags.contains(.beat)) && resolvedTimeDomain == nil {
        resolvedTimeDomain = configuration.amplitudeAnalyzerConfiguration
        processorLog.warning(
          "Analysis work requested without a timeDomain configuration; using defaults.",
        )
      }

      var resolvedFrequencyWork: FrequencyDomainWork?
      if flags.contains(.frequencyDomain) {
        if let frequencyWork = analysisWork?.frequencyDomain {
          resolvedFrequencyWork = normalizedFrequencyWork(frequencyWork)
        } else if let frequencyConfig = configuration.frequencyAnalyzerConfiguration {
          resolvedFrequencyWork = FrequencyDomainWork(
            configuration: frequencyConfig,
            bucketMode: configuration.bucketMode,
            weighting: configuration.frequencyWeighting,
          )
          processorLog.warning(
            "Analysis frequency domain requested without a configuration; using defaults.",
          )
        }
      }

      var resolvedBeatDetection: BeatDetectionConfiguration?
      if flags.contains(.beat) {
        resolvedBeatDetection =
          analysisWork?.beatDetection ?? configuration.beatDetectionConfiguration
      }

      let newConfig = AnalysisConfig(
        timeDomain: resolvedTimeDomain,
        frequencyDomain: resolvedFrequencyWork,
        beatDetection: resolvedBeatDetection,
      )

      let needsRebuild = analysisPipeline == nil || analysisConfig != newConfig
      guard needsRebuild else { return }

      analysisEnabledAtomic.store(false, ordering: .relaxed)
      analysisTicker.cancel()
      analysisTicker.syncBarrier()

      analysisPipeline = AnalysisPipeline(config: newConfig, sampleRate: configuration.sampleRate)
      analysisConfig = newConfig

      if let analyzer = analysisPipeline?.frequencyAnalyzer {
        callbacks.onFrequencyLabelsChanged(analyzer.getFrequencyLabels())
      } else {
        callbacks.onFrequencyLabelsChanged([])
      }

      analysisEnabledAtomic.store(true, ordering: .relaxed)
    }

    private func updateAnalysisCadenceIfNeeded() {
      analysisTicker.cancel()

      guard isActiveAtomic.load(ordering: .relaxed) else { return }
      guard analysisEnabledAtomic.load(ordering: .relaxed) else { return }
      guard let updateRateHz = analysisUpdateRateHz else { return }

      let interval = 1.0 / max(updateRateHz, 1)
      analysisTicker.start(interval: interval) { [weak self] in
        self?.updateVisualizations()
      }
    }

    private func updateLodPublishCadenceIfNeeded() {
      lodPublishTicker.cancel()

      guard isActiveAtomic.load(ordering: .relaxed) else { return }
      guard let rateHz = lodPublishRateHz else { return }

      let interval = 1.0 / max(rateHz, 1)
      lodPublishTicker.start(interval: interval, leeway: .milliseconds(1)) { [weak self] in
        self?.publishLODSnapshot()
      }
    }

    private func updateAudioBuffer(_ data: UnsafeBufferPointer<Float>) {
      guard !data.isEmpty else { return }
      unsafe analysisPipeline?.ringBuffer.write(data)
    }

    private func updateVisualizations() {
      guard analysisEnabledAtomic.load(ordering: .relaxed),
        let pipeline = analysisPipeline
      else { return }

      let flags = AnalysisFlags(rawValue: analysisFlagsAtomic.load(ordering: .relaxed))
      guard !flags.isEmpty else { return }

      let desiredSamples = pipeline.maxVisualizationSamples
      var readCount = 0

      unsafe pipeline.readScratchBuffer.withUnsafeMutableBufferPointer { bufferPointer in
        guard let base = bufferPointer.baseAddress else { return }
        let limitedBuffer = unsafe UnsafeMutableBufferPointer(start: base, count: desiredSamples)
        readCount = unsafe pipeline.ringBuffer.read(into: limitedBuffer)
      }

      guard readCount > 0 else { return }

      let sampleRate = currentSampleRate
      let latestEnd = latestEndSampleTimeAtomic.load(ordering: .relaxed)
      let lastEnd = lastBeatUpdateEndSampleTimeAtomic.exchange(latestEnd, ordering: .relaxed)
      let deltaSamples = max(Int64(0), latestEnd - lastEnd)
      let deltaTime = Double(deltaSamples) / max(sampleRate, 1)
      let audioChunk = Array(pipeline.readScratchBuffer.prefix(readCount))

      var amplitudeResult: AmplitudeData?
      if flags.contains(.timeDomain) || flags.contains(.beat),
        let amplitudeAnalyzer = pipeline.amplitudeAnalyzer
      {
        amplitudeResult = amplitudeAnalyzer.processAmplitudeData(audioChunk)
      }

      var spectrumResult: SpectrumData?
      if flags.contains(.frequencyDomain), let frequencyAnalyzer = pipeline.frequencyAnalyzer {
        spectrumResult = frequencyAnalyzer.processFrequencyData(audioChunk)
      }

      var newTimeDomain: TimeDomainData?
      if flags.contains(.timeDomain), let amplitudeResult {
        newTimeDomain = TimeDomainData(
          samples: amplitudeResult.amplitudes,
          peaks: amplitudeResult.peaks,
          rmsLevel: amplitudeResult.rms,
          level: amplitudeResult.overallLevel,
        )
      }

      var newFrequencyDomain: FrequencyDomainData?
      var newSpectrumPeakHold: [Float] = []
      if flags.contains(.frequencyDomain),
        let spectrumResult,
        let bucketer = pipeline.frequencyBucketer
      {
        let buckets = bucketer.bucket(
          spectrum: spectrumResult.spectrum,
          frequencies: spectrumResult.frequencies,
        )

        newFrequencyDomain = FrequencyDomainData(
          buckets: buckets,
          rawSpectrum: spectrumResult.spectrum,
          frequencies: spectrumResult.frequencies,
          peakFrequency: spectrumResult.peakFrequency,
          spectralCentroid: spectrumResult.spectralCentroid,
        )

        let decayRate = pipeline.peakHoldDecayRate
        newSpectrumPeakHold = updateSpectrumPeaks(
          current: spectrumPeakHold,
          newSpectrum: spectrumResult.spectrum,
          decayRate: decayRate,
        )
        spectrumPeakHold = newSpectrumPeakHold
      }

      var beatInfo: BeatInfo?
      if flags.contains(.beat), let beatDetector = pipeline.beatDetector {
        let rmsLevel = amplitudeResult?.rms ?? 0
        beatInfo = beatDetector.analyze(
          spectrum: spectrumResult?.spectrum ?? [],
          rmsLevel: rmsLevel,
          deltaTime: deltaTime,
        )
      }

      callbacks.onAnalysisFrame(
        AnalysisFrame(
          timeDomain: newTimeDomain,
          frequencyDomain: newFrequencyDomain,
          spectrumPeakHold: newSpectrumPeakHold,
          beat: beatInfo,
        ),
      )
    }

    private func publishLODSnapshot() {
      guard lodEnabledAtomic.load(ordering: .relaxed), unsafe lodProcessor != nil else { return }
      callbacks.onLODSnapshot()
    }

    #if DEBUG
      func publishLODSnapshotForTesting() {
        publishLODSnapshot()
      }
    #endif

    private func updateSpectrumPeaks(
      current: [Float],
      newSpectrum: [Float],
      decayRate: Float,
    ) -> [Float] {
      var peaks: [Float] =
        if current.count != newSpectrum.count {
          Array(repeating: 0.0, count: newSpectrum.count)
        } else {
          current
        }

      for index in newSpectrum.indices {
        let decayed = max(0.0, peaks[index] - decayRate)
        peaks[index] = max(decayed, newSpectrum[index])
      }

      return peaks
    }
  }
#endif
