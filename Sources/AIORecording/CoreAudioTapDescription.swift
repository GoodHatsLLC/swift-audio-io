// © GoodHatsLLC

#if os(macOS)
  import AIOAudioSession
  import CoreAudio

  /// Builds a `CATapDescription` from the public `SystemAudioRecordingInput`,
  /// resolving self-exclusion to a process object id (or the host bundle id as a
  /// fallback). Pure and side-effect free, so it is unit-testable without the HAL.
  enum CoreAudioTapDescriptionBuilder {
    static func make(
      input: SystemAudioRecordingInput,
      currentProcessObjectID: SystemAudioProcessObjectID?,
      hostBundleIdentifier: String?,
    ) -> CATapDescription {
      let isMono = input.format.channels.count <= 1
      let selection = input.processSelection

      var objectIDs = selection.processObjectIDs.map { AudioObjectID($0.rawValue) }
      var bundleIDs = selection.bundleIdentifiers

      // Self-exclusion only makes sense for the global/exclude mode (include-only
      // already captures just the listed processes). Prefer the process object
      // id; fall back to the host bundle identifier when the lookup failed.
      if input.excludesCurrentProcess, selection.mode == .exclude {
        if let current = currentProcessObjectID {
          if !objectIDs.contains(current.rawValue) {
            objectIDs.append(current.rawValue)
          }
        } else if let host = hostBundleIdentifier, !bundleIDs.contains(host) {
          bundleIDs.append(host)
        }
      }

      let description: CATapDescription
      switch selection.mode {
      case .includeOnly:
        description =
          isMono
          ? CATapDescription(monoMixdownOfProcesses: objectIDs)
          : CATapDescription(stereoMixdownOfProcesses: objectIDs)
      case .exclude:
        description =
          isMono
          ? CATapDescription(monoGlobalTapButExcludeProcesses: objectIDs)
          : CATapDescription(stereoGlobalTapButExcludeProcesses: objectIDs)
      }

      description.name = input.tapName
      description.isPrivate = true
      description.muteBehavior = .unmuted

      if !bundleIDs.isEmpty {
        description.bundleIDs = bundleIDs
        description.isProcessRestoreEnabled = selection.restoresProcessesByBundleIdentifier
      }

      return description
    }
  }
#endif
