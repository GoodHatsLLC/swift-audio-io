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

      @MainActor
      func setSampleRate(_ newValue: SampleRate, persistPreference: Bool) {
        owner.errorManager.report {
          try owner.env.request(sampleRate: newValue)
          owner._selectedSampleRate = newValue
          owner.callbackTasks.run { [weak owner] in
            guard let owner else { return }
            let actual = owner.env.sampleRate
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
              if persistPreference {
                persistInputPreferencesIfNeeded { prefs in
                  var rejected = Set(prefs.rejectedSampleRatesHz ?? [])
                  rejected.insert(newValue.hz)
                  rejected.remove(actual.hz)
                  prefs.rejectedSampleRatesHz = rejected.sorted()
                }
              }
              owner._selectedSampleRate = actual
            }
            if persistPreference {
              persistInputPreferencesIfNeeded { prefs in
                prefs.sampleRateHz = actual.hz
              }
            }
          }
        } catch: { error in
          let actual = owner.env.sampleRate
          owner._selectedSampleRate = owner.env.sampleRate
          audioInputPreferenceLog.error(
            """
            􁐚 Sample rate \(newValue, privacy: .public) failed with: \(error, privacy: .public) \
            Rate is \(actual, privacy: .public).
            """,
          )
          if persistPreference {
            persistInputPreferencesIfNeeded { prefs in
              prefs.sampleRateHz = actual.hz
              var rejected = Set(prefs.rejectedSampleRatesHz ?? [])
              rejected.insert(newValue.hz)
              rejected.remove(actual.hz)
              prefs.rejectedSampleRatesHz = rejected.sorted()
            }
          }
        }
      }

      @MainActor
      func setSelectedInput(_ newValue: AudioInput?) {
        do {
          try owner.env.request(input: newValue)

          var validSources = owner.env.input?.availableSources ?? []
          var selectedSource = owner.env.source
          if let currentSource = selectedSource, validSources.contains(currentSource) {
            selectedSource = currentSource
          } else {
            selectedSource = nil
            do {
              if let fallback = validSources.first {
                try owner.env.request(source: fallback)
                selectedSource = owner.env.source
              } else {
                try owner.env.request(source: nil)
              }
            } catch {
              owner.errorManager.enqueue(error)
            }
          }

          validSources = owner.env.input?.availableSources ?? validSources
          owner.state = AudioEnvironmentState.current(
            env: owner.env,
            availableSources: validSources,
            selectedSource: selectedSource,
          )
          persistInputPreferencesIfNeeded { prefs in
            prefs.sampleRateHz = owner.env.sampleRate.hz
            prefs.channelCount = owner.channels.count
            prefs.sourceId = owner.env.source?.id
          }
        } catch {
          owner.errorManager.enqueue(error)
        }
      }

      @MainActor
      func setSelectedSource(_ newValue: AudioSource?) {
        if let newValue, !owner.availableSources.contains(newValue) {
          owner._selectedSource = owner.env.source
          return
        }
        do {
          try owner.env.request(source: newValue)
          owner.state = AudioEnvironmentState.current(env: owner.env)
          persistInputPreferencesIfNeeded { prefs in
            prefs.sourceId = owner.env.source?.id
          }
        } catch {
          owner.state = AudioEnvironmentState.current(
            env: owner.env,
            availableSources: owner.env.input?.availableSources ?? [],
          )
          owner.errorManager.enqueue(error)
          persistInputPreferencesIfNeeded { prefs in
            prefs.sourceId = owner.env.source?.id
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

            try await Self.executeStereoPreference(
              candidates: candidates,
              input: input,
              session: session,
              currentOrientation: currentOrientation,
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
      ) async throws {
        let work = DetachedOwnedWork<Result<Void, any Error>> {
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
        try await work.value.get()
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

        try await AudioEnvironmentManager.executeInputConfiguration(plan, session: owner.session)

        if persistPreference {
          persistInputPreferencesIfNeeded { prefs in
            prefs.sourceId = owner.env.source?.id
          }
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
