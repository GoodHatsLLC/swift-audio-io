// © GoodHatsLLC

#if os(iOS)
  extension AudioEnvironmentManager {
    package struct AudioEnvironmentState {
      let input: AudioInput?
      let selectedSource: AudioSource?
      let selectedSampleRate: SampleRate
      let availableInputs: [AudioInput]
      let availableSources: [AudioSource]
      let selectedNumberOfChannels: ChannelCount

      static func mirrored(
        env: AudioEnvironment,
        sourceFilter: ([AudioSource], ChannelCount) -> [AudioSource],
      ) -> Self {
        let selectedNumberOfChannels = env.input?.channelCount ?? .mono
        let availableSources = sourceFilter(env.availableSources, selectedNumberOfChannels)
        let selectedSource = env.source.flatMap { source in
          availableSources.first(where: { $0 == source })
        }
        return .init(
          input: env.input,
          selectedSource: selectedSource,
          selectedSampleRate: env.sampleRate,
          availableInputs: env.availableInputs,
          availableSources: availableSources,
          selectedNumberOfChannels: selectedNumberOfChannels,
        )
      }

      static func current(
        env: AudioEnvironment,
        availableSources: [AudioSource]? = nil,
        selectedSource: AudioSource? = nil,
      ) -> Self {
        .init(
          input: env.input,
          selectedSource: selectedSource ?? env.source,
          selectedSampleRate: env.sampleRate,
          availableInputs: env.availableInputs,
          availableSources: availableSources ?? env.availableSources,
          selectedNumberOfChannels: env.input?.channelCount ?? .mono,
        )
      }

      /// Off-main variant of ``mirrored(env:sourceFilter:)``.
      ///
      /// `mirrored` performs ~5 synchronous `AVAudioSession` reads
      /// (`currentRoute`, `availableInputs`, `inputDataSource(s)`, `sampleRate`),
      /// each a mediaserverd XPC round-trip. `@concurrent` runs them off the main
      /// actor (required under this package's `NonisolatedNonsendingByDefault`);
      /// the caller assigns the returned snapshot to cached state back on main.
      @concurrent
      static func mirroredOffMain(
        env: AudioEnvironment,
        sourceFilter: @escaping @Sendable ([AudioSource], ChannelCount) -> [AudioSource],
      ) async -> Self {
        mirrored(env: env, sourceFilter: sourceFilter)
      }
    }
  }
#endif
