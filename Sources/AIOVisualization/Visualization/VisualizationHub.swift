// © GoodHatsLLC

#if canImport(AVFAudio)
  import AIOSupport
  import AudioSignals
  import Foundation
  import os
  import Tools

  private let hubLog = SystemLog.make()

  // SAFETY: Mutable subscriber state is protected by `subscriberLock`; dispatch snapshots are copied.
  final class VisualizationHub: @unchecked Sendable {
    typealias SubscriberEventHandler = (VisualizationEvent) -> Void

    struct DemandResolution {
      let hasSubscribers: Bool
      let work: VisualizationWork
    }

    struct Dispatcher {
      private let subscribers: [SubscriberState]

      fileprivate init(subscribers: [SubscriberState]) {
        self.subscribers = subscribers
      }

      func deliver(_ event: VisualizationEvent) {
        for subscriber in subscribers where Self.accepts(event, mask: subscriber.request.eventMask)
        {
          subscriber.eventHandler(event)
        }
      }

      private static func accepts(
        _ event: VisualizationEvent,
        mask: VisualizationEventMask,
      ) -> Bool {
        switch event {
        case .lodSnapshot:
          mask.contains(.lodSnapshot)
        case .lodSnapshotBackground:
          mask.contains(.lodSnapshotBackground)
        case .timeDomain:
          mask.contains(.timeDomain)
        case .frequencyDomain:
          mask.contains(.frequencyDomain)
        case .beat:
          mask.contains(.beat)
        case .latestBufferTiming:
          mask.contains(.latestBufferTiming)
        }
      }
    }

    fileprivate struct SubscriberState {
      let id: UUID
      var request: VisualizationRequest
      let eventHandler: SubscriberEventHandler
    }

    private let configuration: AudioVisualizationEngine.Configuration
    private let subscriberLock = NSLock()
    private var subscribersById: [UUID: SubscriberState] = [:]
    private var subscriberOrder: [UUID] = []

    init(configuration: AudioVisualizationEngine.Configuration) {
      self.configuration = configuration
    }

    func addSubscriber(
      id: UUID,
      request: VisualizationRequest,
      eventHandler: @escaping SubscriberEventHandler,
    ) -> DemandResolution {
      subscriberLock.lock()
      defer { subscriberLock.unlock() }

      let state = SubscriberState(
        id: id,
        request: request,
        eventHandler: eventHandler,
      )
      subscribersById[id] = state
      subscriberOrder.append(id)
      return demandResolutionLocked()
    }

    func removeSubscriber(id: UUID) -> DemandResolution? {
      subscriberLock.lock()
      defer { subscriberLock.unlock() }

      guard subscribersById.removeValue(forKey: id) != nil else { return nil }
      subscriberOrder.removeAll { $0 == id }
      return demandResolutionLocked()
    }

    func dispatcher() -> Dispatcher {
      subscriberLock.lock()
      let subscribers = orderedSubscribersLocked()
      subscriberLock.unlock()
      return Dispatcher(subscribers: subscribers)
    }

    private func demandResolutionLocked() -> DemandResolution {
      let subscribers = orderedSubscribersLocked()
      return DemandResolution(
        hasSubscribers: !subscribers.isEmpty,
        work: aggregatedWork(from: subscribers),
      )
    }

    private func orderedSubscribersLocked() -> [SubscriberState] {
      subscriberOrder.compactMap { subscribersById[$0] }
    }

    private func aggregatedWork(from subscribers: [SubscriberState]) -> VisualizationWork {
      guard !subscribers.isEmpty else { return .none }

      var selectedLodConfig: MultiBandLODConfiguration?
      var maxLodPublishRate: Double?

      var analysisRequested = false
      var selectedAnalysisUpdateRate: Double?
      var selectedTimeDomain: AmplitudeAnalyzer.Configuration?
      var selectedFrequencyDomain: FrequencyDomainWork?
      var selectedBeatDetection: BeatDetectionConfiguration?

      for subscriber in subscribers {
        let work = subscriber.request.work

        if let lodWork = work.lod {
          let normalizedConfig = normalizedLODConfig(lodWork.configuration)
          if let selectedLodConfig, selectedLodConfig != normalizedConfig {
            hubLog.warning(
              "Conflicting LOD configurations across subscribers. Using the first requested configuration.",
            )
          } else {
            selectedLodConfig = normalizedConfig
          }
          maxLodPublishRate = max(maxLodPublishRate ?? 0, lodWork.publishRateHz)
        }

        guard let analysisWork = work.analysis else { continue }
        analysisRequested = true
        selectedAnalysisUpdateRate = max(
          selectedAnalysisUpdateRate ?? 0,
          analysisWork.updateRateHz,
        )

        if selectedTimeDomain == nil {
          selectedTimeDomain = analysisWork.timeDomain
        } else if let requested = analysisWork.timeDomain, selectedTimeDomain != requested {
          hubLog.warning(
            "Conflicting time-domain configurations across subscribers. Using the first requested configuration.",
          )
        }

        if let frequencyDomainWork = analysisWork.frequencyDomain {
          let normalizedFrequency = normalizedFrequencyWork(frequencyDomainWork)
          if let selectedFrequencyDomain, selectedFrequencyDomain != normalizedFrequency {
            hubLog.warning(
              "Conflicting frequency-domain configurations across subscribers. Using the first requested configuration.",
            )
          } else {
            selectedFrequencyDomain = normalizedFrequency
          }
        }

        if let beatDetection = analysisWork.beatDetection {
          if let selectedBeatDetection, selectedBeatDetection != beatDetection {
            hubLog.warning(
              "Conflicting beat-detection configurations across subscribers. Using the first requested configuration.",
            )
          } else {
            selectedBeatDetection = beatDetection
          }
        }
      }

      var resolvedLodWork: LODWork?
      if let selectedLodConfig {
        resolvedLodWork = LODWork(
          configuration: selectedLodConfig,
          publishRateHz: maxLodPublishRate ?? VisualizationRateDefaults.lodPublishRateHz,
        )
      }

      var resolvedAnalysisWork: AnalysisWork?
      let hasAnyAnalysisDemand =
        selectedTimeDomain != nil
        || selectedFrequencyDomain != nil
        || selectedBeatDetection != nil
      if analysisRequested, hasAnyAnalysisDemand {
        resolvedAnalysisWork = AnalysisWork(
          updateRateHz: selectedAnalysisUpdateRate ?? configuration.analysisUpdateRateHz,
          timeDomain: selectedTimeDomain,
          frequencyDomain: selectedFrequencyDomain,
          beatDetection: selectedBeatDetection,
        )
      }

      return VisualizationWork(
        lod: resolvedLodWork,
        analysis: resolvedAnalysisWork,
      )
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
  }
#endif
