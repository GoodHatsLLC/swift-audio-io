// © GoodHatsLLC

#if canImport(AVFoundation)
  import Testing
  @testable import AIORecording

  struct RecordingInputChannelContractTests {
    @Test
    func `stereo request rejects a mono route`() {
      #expect(throws: SessionError.self) {
        try RecordingInputChannelContract.validateRouteCapacity(requested: 2, maximum: 1)
      }
    }

    @Test
    func `stereo request rejects a mono capture format`() {
      #expect(throws: SessionError.self) {
        try RecordingInputChannelContract.validateCaptureFormat(requested: 2, actual: 1)
      }
    }

    @Test
    func `mono processing may downmix stereo hardware`() throws {
      try RecordingInputChannelContract.validateRouteCapacity(requested: 1, maximum: 2)
      try RecordingInputChannelContract.validateCaptureFormat(requested: 1, actual: 2)
    }

    @Test
    func `stereo capture satisfies a stereo request`() throws {
      try RecordingInputChannelContract.validateRouteCapacity(requested: 2, maximum: 2)
      try RecordingInputChannelContract.validateCaptureFormat(requested: 2, actual: 2)
    }
  }
#endif
