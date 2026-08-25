// © GoodHatsLLC

#if canImport(AVFoundation)
  @testable import AIOEngineCore
  import Testing

  /// The channel contract adapts the source to the requested layout; it
  /// never refuses. A narrower route is replicated, a wider one downmixed.
  struct RecordingInputChannelContractTests {
    @Test
    func `a mono route is replicated into a stereo contract`() {
      #expect(
        RecordingInputChannelContract.adaptation(requested: 2, actual: 1)
          == .replicate(source: 1, contract: 2),
      )
      #expect(RecordingInputChannelContract.replicationChannelMap(source: 1, contract: 2) == [0, 0])
    }

    @Test
    func `a stereo route is downmixed into a mono contract`() {
      #expect(
        RecordingInputChannelContract.adaptation(requested: 1, actual: 2)
          == .downmix(source: 2, contract: 1),
      )
      #expect(RecordingInputChannelContract.replicationChannelMap(source: 2, contract: 1) == nil)
    }

    @Test
    func `a matching route passes through`() {
      #expect(
        RecordingInputChannelContract.adaptation(requested: 2, actual: 2)
          == .passthrough(channels: 2),
      )
      #expect(RecordingInputChannelContract.replicationChannelMap(source: 2, contract: 2) == nil)
    }

    @Test
    func `the route is asked for no more channels than it has`() {
      #expect(RecordingInputChannelContract.preferredRouteChannels(requested: 2, maximum: 1) == 1)
      #expect(RecordingInputChannelContract.preferredRouteChannels(requested: 1, maximum: 2) == 1)
      #expect(RecordingInputChannelContract.preferredRouteChannels(requested: 2, maximum: 0) == 1)
    }

    @Test
    func `replication maps every extra contract channel to the last source channel`() {
      #expect(
        RecordingInputChannelContract.replicationChannelMap(source: 2, contract: 4) == [0, 1, 1, 1],
      )
      #expect(RecordingInputChannelContract.replicationChannelMap(source: 0, contract: 2) == nil)
    }
  }
#endif
