// © GoodHatsLLC

#if os(iOS)
  import AIOSupport
  import AVFAudio
  import os
  import Tools

  private let audioInputPreferenceLog = SystemLog.make()

  extension AudioEnvironmentManager {
    package struct AudioInputPreferenceController {
      let owner: AudioEnvironmentManager

      // The three bindable setters below are synchronous `@MainActor` properties
      // that cannot `await`, yet each drives a blocking `setPreferred*` XPC
      // round-trip to `mediaserverd` (100–500 ms). They enqueue the whole
      // read-write sequence onto ``inputWriteQueue`` (FIFO, off-main), so the
      // main thread never blocks and the writes never overlap any other
      // input-preference write. The input/source setters commit a full hardware
      // re-read (``AudioEnvironmentState/current(env:availableSources:selectedSource:)``)
      // on a main hop; `setSampleRate` updates only `_selectedSampleRate` (the
      // sole field a rate change affects), matching the original. `isRestoringFromDefaults`
      // is sampled synchronously at call time (matching the old inline behavior)
      // and used to suppress persistence during a restore.

      @MainActor
      func setSampleRate(_ newValue: SampleRate, persistPreference: Bool) {
        let suppressRestore = owner.isRestoringFromDefaults
        owner.inputWriteQueue.enqueue { [self] in
          let env = owner.env
          // Logging and error handling stay off-main (os.Logger and
          // `errorManager` are both thread-safe), so only Sendable scalars cross
          // to the main hop — avoids smuggling a non-Sendable `any Error`.
          var failed = false
          do {
            try env.request(sampleRate: newValue)
          } catch {
            failed = true
            audioInputPreferenceLog.error(
              """
              􁐚 Sample rate \(newValue, privacy: .public) failed with: \
              \(error, privacy: .public) Rate is \(env.sampleRate, privacy: .public).
              """,
            )
          }
          let actual = env.sampleRate
          if !failed {
            if actual == newValue {
              audioInputPreferenceLog.info(
                "􁐚 Sample rate set to requested value: \(newValue, privacy: .public)",
              )
            } else {
              audioInputPreferenceLog.info(
                """
                􁐚 Sample rate \(newValue, privacy: .public) rejected. \
                Set to \(actual, privacy: .public)
                """,
              )
            }
          }
          let rejectedOrFailed = failed || actual != newValue
          let baseline = persistBaseline(env: env)
          let persistAllowed = persistPreference && !suppressRestore

          await MainActor.run {
            // A sample-rate request changes only the rate — not the data source,
            // available sources, inputs, or channel config — so (matching the
            // original) update only `_selectedSampleRate`. A full re-mirror via
            // `current(env:)` would reintroduce mono-hidden stereo-only sources
            // and overwrite the selected source.
            owner._selectedSampleRate = actual
            guard persistAllowed else { return }
            persistFromBaseline(baseline) { prefs in
              prefs.sampleRateHz = actual.hz
              if rejectedOrFailed {
                var rejected = Set(prefs.rejectedSampleRatesHz ?? [])
                rejected.insert(newValue.hz)
                rejected.remove(actual.hz)
                prefs.rejectedSampleRatesHz = rejected.sorted()
              }
            }
          }
        }
      }

      @MainActor
      func setSelectedInput(_ newValue: AudioInput?) {
        let suppressRestore = owner.isRestoringFromDefaults
        let isAudioSessionActive = owner.isAudioSessionActive
        owner.inputWriteQueue.enqueue { [self] in
          let env = owner.env
          do {
            if isAudioSessionActive {
              try env.request(input: newValue)
            }

            let activeInput = env.input
            let routeMatchesRequest =
              newValue == nil || activeInput?.id == newValue?.id
            let resolvedInput =
              routeMatchesRequest
              ? (activeInput ?? newValue)
              : (newValue ?? activeInput)
            let selectedNumberOfChannels = resolvedInput?.channelCount ?? .mono
            var validSources = owner.filterSources(
              resolvedInput?.availableSources ?? [],
              for: selectedNumberOfChannels,
            )
            var selectedSource =
              if routeMatchesRequest {
                env.source
              } else {
                resolvedInput?.selectedSource
              }

            if let currentSource = selectedSource, !validSources.contains(currentSource) {
              selectedSource = nil
            }

            if isAudioSessionActive, routeMatchesRequest, selectedSource == nil {
              do {
                if let fallback = validSources.first, activeInput != nil {
                  try env.request(source: fallback)
                  selectedSource = env.source
                } else {
                  try env.request(source: nil)
                }
              } catch {
                owner.errorManager.enqueue(error)
              }
            }

            if let activeInput = env.input, routeMatchesRequest {
              validSources = owner.filterSources(
                activeInput.availableSources,
                for: activeInput.channelCount,
              )
            }

            let state = AudioEnvironmentState(
              input: resolvedInput,
              selectedSource: selectedSource,
              selectedSampleRate: env.sampleRate,
              availableInputs: (env.availableInputs + [resolvedInput].compactMap { $0 })
                .removingDuplicates(),
              availableSources: validSources,
              selectedNumberOfChannels: selectedNumberOfChannels,
            )
            let baseline = PersistBaseline(
              inputId: resolvedInput?.id ?? "_default",
              currentSampleRate: env.sampleRate,
              isConfiguredForStereo: selectedNumberOfChannels.count > 1,
              currentSourceId: selectedSource?.id,
            )
            let channelCount = selectedNumberOfChannels.count
            let sampleRateHz = env.sampleRate.hz
            let sourceId = selectedSource?.id

            await MainActor.run {
              owner.state = state
              if !suppressRestore {
                owner.preferenceStore.setPreferredInputId(newValue?.id)
                persistFromBaseline(baseline) { prefs in
                  prefs.sampleRateHz = sampleRateHz
                  prefs.channelCount = channelCount
                  prefs.sourceId = sourceId
                }
              }
            }
          } catch {
            owner.errorManager.enqueue(error)
          }
        }
      }

      @MainActor
      func setSelectedSource(_ newValue: AudioSource?) {
        if let newValue, !owner.availableSources.contains(newValue) {
          // Invalid selection: re-sync the cached source from the live route,
          // reading it off-main on the same FIFO queue.
          owner.inputWriteQueue.enqueue { [self] in
            let actual = owner.env.source
            await MainActor.run { owner._selectedSource = actual }
          }
          return
        }
        let suppressRestore = owner.isRestoringFromDefaults
        owner.inputWriteQueue.enqueue { [self] in
          let env = owner.env
          do {
            try env.request(source: newValue)
            let state = AudioEnvironmentState.current(env: env)
            let baseline = persistBaseline(env: env)
            let sourceId = env.source?.id
            await MainActor.run {
              owner.state = state
              if !suppressRestore {
                persistFromBaseline(baseline) { prefs in
                  prefs.sourceId = sourceId
                }
              }
            }
          } catch {
            let state = AudioEnvironmentState.current(
              env: env,
              availableSources: env.input?.availableSources ?? [],
            )
            let baseline = persistBaseline(env: env)
            let sourceId = env.source?.id
            owner.errorManager.enqueue(error)  // nonisolated; keep off the main hop
            await MainActor.run {
              owner.state = state
              if !suppressRestore {
                persistFromBaseline(baseline) { prefs in
                  prefs.sourceId = sourceId
                }
              }
            }
          }
        }
      }

      @MainActor
      func applyMono(persistPreference: Bool) async throws(ManagerError) {
        if persistPreference {
          persistInputPreferencesIfNeeded { prefs in
            prefs.channelCount = ChannelCount.mono.count
          }
        }

        var plan = AudioEnvironmentManager.InputConfigurationPlan()
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
            let monoCapable = allSources.first(where: {
              !$0.supportedPolarPatterns.contains(.stereo)
            }
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

        try await AudioEnvironmentManager.executeInputConfiguration(
          plan, session: owner.session, queue: owner.inputWriteQueue,
        )

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

            try await Self.executeStereoPreference(
              candidates: candidates,
              input: input,
              session: session,
              currentOrientation: currentOrientation,
              queue: owner.inputWriteQueue,
            )

            // Selecting a stereo polar pattern does not itself promise that the
            // session will expose two input channels. Apply the channel-count
            // preference explicitly so the mirrored state below describes a
            // fully configured route rather than a partially selected source.
            var plan = AudioEnvironmentManager.InputConfigurationPlan()
            plan.channelCount = ChannelCount.stereo.count
            try await AudioEnvironmentManager.executeInputConfiguration(
              plan, session: session, queue: owner.inputWriteQueue,
            )
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

      private nonisolated static func executeStereoPreference(
        candidates: [AudioSource],
        input: AudioInput,
        session: AVAudioSession,
        currentOrientation: AVAudioSession.StereoOrientation,
        queue: SerialAsyncWorkQueue,
      ) async throws {
        let outcome: Result<Void, any Error>? = await queue.submit {
          () async -> Result<
            Void, any Error
          > in
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
          if let lastError {
            return .failure(lastError)
          }
          return .success(())
        }
        // `nil` outcome = queue finished during teardown; treat as a no-op.
        try outcome?.get()
      }

      @MainActor
      func applySourceConfiguration(
        source: AudioSource,
        channelCount: ChannelCount,
        polarPattern: PolarPattern?,
        persistPreference: Bool,
      ) async throws(ManagerError) {
        if persistPreference {
          persistInputPreferencesIfNeeded { prefs in
            prefs.channelCount = channelCount.count
          }
        }

        guard let input = owner.env.input else {
          throw .audioEnvironment(.noActiveAudioInputForDataSource)
        }

        var plan = AudioEnvironmentManager.InputConfigurationPlan()
        plan.channelCount = channelCount.count
        plan.preferredInput = input
        plan.preferredSource = source
        plan.polarPatternSource = polarPattern == nil ? nil : source
        plan.polarPattern = polarPattern
        if channelCount.count > 1, owner.orientation != .none {
          plan.inputOrientation = owner.orientation
        }

        defer {
          owner.state = AudioEnvironmentState.mirrored(
            env: owner.env,
            sourceFilter: owner.filterSources,
          )
        }

        try await AudioEnvironmentManager.executeInputConfiguration(
          plan, session: owner.session, queue: owner.inputWriteQueue,
        )

        if persistPreference {
          persistInputPreferencesIfNeeded { prefs in
            prefs.sourceId = owner.env.source?.id
          }
        }
      }

      @discardableResult
      @MainActor
      func updateAudioInputs(reason: String) async -> AudioDeviceChangeSummary? {
        let previousState = owner.state
        // Snapshot the session off the main actor (5 mediaserverd XPC reads),
        // then diff + assign cached state back on main.
        let nextState = await AudioEnvironmentState.mirroredOffMain(
          env: owner.env,
          sourceFilter: owner.filterSources,
        )
        guard
          nextState.availableInputs != previousState.availableInputs
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
        audioInputPreferenceLog.info(
          "\(reason, privacy: .public): \(summary.description, privacy: .public)",
        )
        return summary
      }

      /// The `mediaserverd`-derived baseline that ``persistFromBaseline(_:_:)``
      /// needs, snapshot **off the main actor** so the bindable setters never do
      /// XPC reads on the main thread. Mirrors the reads
      /// ``persistInputPreferencesIfNeeded(_:)`` performs inline.
      struct PersistBaseline: Sendable {
        let inputId: String
        let currentSampleRate: SampleRate
        let isConfiguredForStereo: Bool
        let currentSourceId: String?
      }

      nonisolated private func persistBaseline(env: AudioEnvironment) -> PersistBaseline {
        PersistBaseline(
          inputId: env.input?.id ?? "_default",
          currentSampleRate: env.sampleRate,
          isConfiguredForStereo: env.session.inputNumberOfChannels > 1,
          currentSourceId: env.source?.id,
        )
      }

      /// Persists using a pre-computed off-main ``PersistBaseline``. Unlike
      /// ``persistInputPreferencesIfNeeded(_:)`` this performs no XPC reads (the
      /// caller sampled them off-main) and does not re-check
      /// `isRestoringFromDefaults` — the bindable setters sample that at call
      /// time and gate the call themselves.
      @MainActor
      private func persistFromBaseline(
        _ baseline: PersistBaseline,
        _ update: (inout PersistedInputPreferences) -> Void,
      ) {
        owner.preferenceStore.update(
          inputId: baseline.inputId,
          currentSampleRate: baseline.currentSampleRate,
          isConfiguredForStereo: baseline.isConfiguredForStereo,
          currentSourceId: baseline.currentSourceId,
          update,
        )
      }

      @MainActor
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

      @MainActor
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

        if let current = owner.selectedSource, stereoSources.contains(current),
          !ordered.contains(current)
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
  }
#endif
