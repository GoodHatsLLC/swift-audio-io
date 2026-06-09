// © GoodHatsLLC

#if os(macOS)
  import CoreAudio
  import Testing

  @testable import AIOAudioSession
  @testable import AIORecording

  struct CoreAudioTapDescriptionTests {
    private func input(
      channels: Int,
      selection: SystemAudioProcessSelection,
      excludesCurrentProcess: Bool = true,
    ) -> SystemAudioRecordingInput {
      SystemAudioRecordingInput(
        format: InputConfiguration(sampleRate: .dvd, channels: .init(platform: AVAudioChannelCountValue(channels))),
        processSelection: selection,
        excludesCurrentProcess: excludesCurrentProcess,
        tapName: "Test Tap",
      )
    }

    @Test
    func `default exclude stereo tap is exclusive, stereo, private, named`() {
      let description = CoreAudioTapDescriptionBuilder.make(
        input: input(channels: 2, selection: SystemAudioProcessSelection()),
        currentProcessObjectID: SystemAudioProcessObjectID(rawValue: 42),
        hostBundleIdentifier: "com.example.host",
      )
      #expect(description.isExclusive)
      #expect(!description.isMono)
      #expect(description.isPrivate)
      #expect(description.name == "Test Tap")
      #expect(description.muteBehavior == .unmuted)
    }

    @Test
    func `include-only mono tap is a non-exclusive mono mixdown`() {
      let selection = SystemAudioProcessSelection(
        mode: .includeOnly,
        processObjectIDs: [SystemAudioProcessObjectID(rawValue: 7)],
      )
      let description = CoreAudioTapDescriptionBuilder.make(
        input: input(channels: 1, selection: selection),
        currentProcessObjectID: SystemAudioProcessObjectID(rawValue: 42),
        hostBundleIdentifier: nil,
      )
      #expect(!description.isExclusive)
      #expect(description.isMono)
    }

    @Test
    func `exclude by bundle id sets bundleIDs and restore behavior`() {
      let selection = SystemAudioProcessSelection(
        mode: .exclude,
        bundleIdentifiers: ["com.example.other"],
        restoresProcessesByBundleIdentifier: true,
      )
      let description = CoreAudioTapDescriptionBuilder.make(
        input: input(channels: 2, selection: selection, excludesCurrentProcess: false),
        currentProcessObjectID: nil,
        hostBundleIdentifier: "com.example.host",
      )
      #expect(description.isExclusive)
      #expect(description.bundleIDs.contains("com.example.other"))
      #expect(description.isProcessRestoreEnabled)
    }

    @Test
    func `self-exclusion falls back to host bundle id when object lookup fails`() {
      let description = CoreAudioTapDescriptionBuilder.make(
        input: input(channels: 2, selection: SystemAudioProcessSelection()),
        currentProcessObjectID: nil,
        hostBundleIdentifier: "com.example.host",
      )
      #expect(description.bundleIDs.contains("com.example.host"))
    }
  }

  // ChannelCount(platform:) takes an AVAudioChannelCount (UInt32).
  private typealias AVAudioChannelCountValue = UInt32
#endif
