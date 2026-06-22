// © GoodHatsLLC

#if os(iOS)
  import AIOSupport
  import os
  import Tools

  private let audioInputPreferenceRestorerLog = SystemLog.make()

  extension AudioEnvironmentManager {
    package struct AudioInputPreferenceRestorer {
      let owner: AudioEnvironmentManager

      @MainActor
      func restorePreferredInputAndConfigurationIfPossible(reason: String) async {
        guard !owner.isRestoringFromDefaults else { return }
        owner.isRestoringFromDefaults = true
        defer { owner.isRestoringFromDefaults = false }

        owner.preferenceStore.reload()

        if !owner.isAudioSessionActive,
          let preferredInputId = owner.preferenceStore.preferredInputId,
          let preferredInput = owner.env.availableInputs.first(where: { $0.id == preferredInputId }
          ),
          owner.env.input?.id != preferredInputId
        {
          do {
            try owner.env.request(input: preferredInput)
          } catch {
            owner.errorManager.enqueue(error)
          }
        }

        owner.state = await AudioEnvironmentState.mirroredOffMain(
          env: owner.env,
          sourceFilter: owner.filterSources,
        )

        let inputId = owner.env.input?.id ?? "_default"
        let canApplyPreferences = owner.isAudioSessionActive
        let modeStatus = canApplyPreferences ? "applied" : "deferred"
        if let prefs = owner.preferenceStore.preferences(for: inputId) {
          if canApplyPreferences {
            if let sampleRateHz = prefs.sampleRateHz {
              owner.sampleRate = SampleRate(sampleRateHz)
            }

            if let channelCount = prefs.channelCount {
              do {
                if channelCount > 1 {
                  try await owner.applyStereo()
                } else {
                  try await owner.applyMono()
                }
              } catch {
                owner.errorManager.enqueue(error)
              }
            }

            if let sourceId = prefs.sourceId {
              let desired = owner.availableSources.first(where: { $0.id == sourceId })
              if desired != nil {
                owner.selectedSource = desired
              } else if owner.inputHasStereoSource,
                owner.shouldAutoSelectStereoWhenAvailable == false
              {
                do {
                  try await owner.applyStereo()
                } catch {
                  owner.errorManager.enqueue(error)
                }
              }
            }
          } else {
            audioInputPreferenceRestorerLog.info(
              "Skipping input preference restore; audio session inactive (\(reason, privacy: .public))",
            )
          }
        } else if canApplyPreferences {
          if owner.inputHasStereoSource {
            do {
              try await owner.applyStereo()
            } catch {
              owner.errorManager.enqueue(error)
            }
          }
        } else {
          audioInputPreferenceRestorerLog.info(
            "Skipping input preference defaults; audio session inactive (\(reason, privacy: .public))",
          )
        }

        audioInputPreferenceRestorerLog.info(
          "Restored audio environment preferences (\(reason, privacy: .public); \(modeStatus, privacy: .public))",
        )
      }
    }
  }
#endif
