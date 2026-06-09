// © GoodHatsLLC

#if os(macOS)
  import Testing

  @testable import AIOAudioSession

  struct SystemAudioRecordingInputTests {
    private func stereo() -> InputConfiguration {
      InputConfiguration(sampleRate: .dvd, channels: .init(platform: 2))
    }

    private func output() -> OutputConfiguration {
      OutputConfiguration(fileFormat: .caf, bitDepth: .pcmFloat32, quality: .high)
    }

    @Test
    func `system audio input defaults exclude the current process`() {
      let input = SystemAudioRecordingInput(format: stereo())
      #expect(input.excludesCurrentProcess)
      #expect(input.processSelection.mode == .exclude)
      #expect(input.processSelection.processObjectIDs.isEmpty)
      #expect(input.tapName == "AudioIO System Audio")
      #expect(input.aggregateDeviceUIDPrefix == "io.audioio.system-audio")
    }

    @Test
    func `configuration exposes the system-audio format and a default tap interval`() {
      let format = stereo()
      let configuration = RecordingConfiguration(
        input: .systemAudio(SystemAudioRecordingInput(format: format)),
        outputConfiguration: output(),
      )
      #expect(configuration.format == format)
      #expect(configuration.input.format == format)
      // System audio has no tap interval; the accessor stays total for the mic
      // tap machinery, returning the default.
      #expect(configuration.tapInterval == .seconds(0.1))
    }

    @Test
    func `process selection carries include and exclude filters`() {
      let selection = SystemAudioProcessSelection(
        mode: .includeOnly,
        processObjectIDs: [SystemAudioProcessObjectID(rawValue: 42)],
        bundleIdentifiers: ["com.example.app"],
        restoresProcessesByBundleIdentifier: true,
      )
      #expect(selection.mode == .includeOnly)
      #expect(selection.processObjectIDs == [SystemAudioProcessObjectID(rawValue: 42)])
      #expect(selection.bundleIdentifiers == ["com.example.app"])
      #expect(selection.restoresProcessesByBundleIdentifier)
    }

    @Test
    func `equal system-audio configurations hash equally`() {
      let a = RecordingConfiguration(
        input: .systemAudio(SystemAudioRecordingInput(format: stereo())),
        outputConfiguration: output(),
      )
      let b = RecordingConfiguration(
        input: .systemAudio(SystemAudioRecordingInput(format: stereo())),
        outputConfiguration: output(),
      )
      #expect(a == b)
      #expect(a.hashValue == b.hashValue)
    }

    // Discovery hits the real HAL. In a CLI/test context the process list may be
    // empty and the current process may have no audio object, so this only
    // asserts the calls are well-formed and any returned entries are coherent.
    @Test
    func `process discovery returns coherent entries without crashing`() throws {
      let processes = try SystemAudioProcessCatalog.capturableProcesses()
      for process in processes {
        if let bundleID = process.bundleIdentifier {
          #expect(!bundleID.isEmpty)
        }
      }
      // currentProcess may be nil in a non-audio CLI process; if present its id
      // must be a usable (non-zero) object id.
      if let current = SystemAudioProcessObjectID.currentProcess {
        #expect(current.rawValue != 0)
      }
    }
  }
#endif
