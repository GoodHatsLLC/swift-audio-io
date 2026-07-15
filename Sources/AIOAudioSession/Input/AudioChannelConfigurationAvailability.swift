// © GoodHatsLLC

#if canImport(AVFoundation)
  /// Describes whether the effective audio input's channel configuration has
  /// resolved and whether the caller can choose between channel counts.
  ///
  /// The effective input is the user's explicit selection when one is
  /// available, otherwise the platform's current/default input. This keeps a
  /// default selection dynamic: resolving its capabilities does not turn it
  /// into a pinned preferred input.
  public enum AudioChannelConfigurationAvailability: Hashable, Sendable {
    /// The audio environment has not resolved an effective input yet.
    case unresolved

    /// The effective input exposes one channel configuration.
    case fixed(ChannelCount)

    /// The effective input lets the caller choose from the supplied channel
    /// configurations.
    case configurable(Set<ChannelCount>)

    /// Channel configurations currently exposed by the effective input.
    public var availableChannelCounts: Set<ChannelCount> {
      switch self {
      case .unresolved:
        []
      case .fixed(let channelCount):
        [channelCount]
      case .configurable(let channelCounts):
        channelCounts
      }
    }
  }
#endif
