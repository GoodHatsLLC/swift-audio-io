// © GoodHatsLLC

#if canImport(AVFoundation)
  import AIOAudioSession

  /// Maps a route's channel count onto the requested capture layout.
  ///
  /// The capture layout is a *contract* fixed when the recording starts; the
  /// route is a *source* that may deliver more or fewer channels than that,
  /// at start or at any later moment. Neither case is a failure: a wider
  /// source is downmixed into the layout and a narrower one is replicated
  /// into it (mono is duplicated into both channels of a stereo file). The
  /// file's layout never changes because the route did.
  ///
  /// This replaces the former gate that refused to "manufacture" channels at
  /// bring-up while the route-change path silently did exactly that mid-run.
  /// One rule now covers both moments, and it never throws.
  package enum RecordingInputChannelContract {
    /// How the installed source maps onto the contract.
    package enum Adaptation: Hashable, Sendable, CustomStringConvertible {
      case passthrough(channels: Int)
      /// The source has more channels than the contract; the surplus is mixed
      /// down (2→1 averages, N→2 takes the first two).
      case downmix(source: Int, contract: Int)
      /// The source has fewer channels than the contract; the last source
      /// channel is duplicated into every contract channel it cannot fill.
      case replicate(source: Int, contract: Int)

      package var description: String {
        switch self {
        case .passthrough(let channels):
          "\(channels)ch pass-through"
        case .downmix(let source, let contract):
          "downmix \(source)ch → \(contract)ch"
        case .replicate(let source, let contract):
          "replicate \(source)ch → \(contract)ch"
        }
      }
    }

    package static func adaptation(requested: Int, actual: Int) -> Adaptation {
      if actual == requested {
        return .passthrough(channels: requested)
      }
      if actual > requested {
        return .downmix(source: actual, contract: requested)
      }
      return .replicate(source: max(actual, 1), contract: requested)
    }

    /// The channel count to *prefer* on the platform session: the request,
    /// capped at what the route can carry. Asking a route for more channels
    /// than it has is a platform error, not a request, so the surplus is left
    /// to replication.
    package static func preferredRouteChannels(requested: Int, maximum: Int) -> Int {
      max(1, min(requested, max(maximum, 1)))
    }

    /// The converter channel map that realises ``Adaptation/replicate``:
    /// every contract channel reads the matching source channel, and the ones
    /// past the source's width read its last channel. `nil` when no map is
    /// needed (the converter's own downmix/pass-through is used).
    package static func replicationChannelMap(source: Int, contract: Int) -> [Int]? {
      guard source > 0, contract > source else { return nil }
      return (0..<contract).map { min($0, source - 1) }
    }
  }
#endif
