// © GoodHatsLLC

#if os(macOS)
  import AppKit
  import CoreAudio
  import Foundation

  // MARK: - Public configuration

  /// System-audio (Core Audio process tap) capture options.
  ///
  /// Available only on macOS. Global process taps are mono or stereo mixdowns,
  /// so `format.channels` must be 1 or 2 (enforced at `warm()`).
  public struct SystemAudioRecordingInput: Hashable, Sendable {
    /// The requested processing format (sample rate + channel count). Mono or
    /// stereo only for system audio.
    public var format: InputConfiguration

    /// Which processes to capture (include-only or exclude), by audio object ID
    /// and/or bundle identifier.
    public var processSelection: SystemAudioProcessSelection

    /// Excludes the host process from the tap so the recorder never captures its
    /// own output (prevents feedback). Resolved to the host's audio object ID, or
    /// the host bundle identifier if the object lookup fails.
    public var excludesCurrentProcess: Bool

    /// Human-readable `CATapDescription.name`.
    public var tapName: String

    /// Reverse-domain prefix for the private aggregate device UID. A unique
    /// UUID suffix is appended per session, so the prefix only namespaces the
    /// device; collisions are avoided by the suffix.
    public var aggregateDeviceUIDPrefix: String

    public init(
      format: InputConfiguration,
      processSelection: SystemAudioProcessSelection = SystemAudioProcessSelection(),
      excludesCurrentProcess: Bool = true,
      tapName: String = "AudioIO System Audio",
      aggregateDeviceUIDPrefix: String = "io.audioio.system-audio",
    ) {
      self.format = format
      self.processSelection = processSelection
      self.excludesCurrentProcess = excludesCurrentProcess
      self.tapName = tapName
      self.aggregateDeviceUIDPrefix = aggregateDeviceUIDPrefix
    }
  }

  /// Which processes a system-audio tap captures.
  public struct SystemAudioProcessSelection: Hashable, Sendable {
    public enum Mode: Hashable, Sendable {
      /// Tap only the listed processes (a mixdown of those processes).
      case includeOnly
      /// Tap everything except the listed processes (a global, exclusive tap).
      case exclude
    }

    public var mode: Mode
    public var processObjectIDs: [SystemAudioProcessObjectID]
    public var bundleIdentifiers: [String]
    /// When `true`, the tap saves listed processes by bundle identifier when they
    /// exit and restores them on relaunch (`CATapDescription.isProcessRestoreEnabled`).
    public var restoresProcessesByBundleIdentifier: Bool

    public init(
      mode: Mode = .exclude,
      processObjectIDs: [SystemAudioProcessObjectID] = [],
      bundleIdentifiers: [String] = [],
      restoresProcessesByBundleIdentifier: Bool = false,
    ) {
      self.mode = mode
      self.processObjectIDs = processObjectIDs
      self.bundleIdentifiers = bundleIdentifiers
      self.restoresProcessesByBundleIdentifier = restoresProcessesByBundleIdentifier
    }
  }

  /// A Core Audio process object identifier (`AudioObjectID`).
  ///
  /// These are opaque and ephemeral; obtain them via ``currentProcess``,
  /// ``init(processID:)``, or ``SystemAudioProcessCatalog/capturableProcesses()``.
  public struct SystemAudioProcessObjectID: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
      self.rawValue = rawValue
    }

    /// The host process's audio object, resolved via the HAL. `nil` when the HAL
    /// has no audio object for the current process.
    public static var currentProcess: SystemAudioProcessObjectID? {
      SystemAudioProcessObjectID(processID: getpid())
    }

    /// Translate a POSIX process id (`pid_t`) to its Core Audio object id via
    /// `kAudioHardwarePropertyTranslatePIDToProcessObject`. `nil` on failure.
    public init?(processID: Int32) {
      guard let objectID = SystemAudioHAL.translate(processID: processID) else { return nil }
      self.rawValue = objectID
    }
  }

  /// A capturable process discovered from the HAL, so callers can build
  /// include / exclude selections without already knowing raw object IDs.
  public struct SystemAudioProcess: Hashable, Sendable, Identifiable {
    /// The Core Audio object id used in `processObjectIDs` selections.
    public var id: SystemAudioProcessObjectID
    /// The POSIX process id (`pid_t`).
    public var processID: Int32
    public var bundleIdentifier: String?
    /// Best-effort localized application name (from `NSRunningApplication`); `nil`
    /// for processes without a GUI application (daemons, helpers).
    public var name: String?

    public init(
      id: SystemAudioProcessObjectID,
      processID: Int32,
      bundleIdentifier: String?,
      name: String?,
    ) {
      self.id = id
      self.processID = processID
      self.bundleIdentifier = bundleIdentifier
      self.name = name
    }
  }

  /// Enumerates processes the HAL currently exposes as audio sources.
  public enum SystemAudioProcessCatalog {
    /// All processes the HAL exposes as audio objects
    /// (`kAudioHardwarePropertyProcessObjectList`), with PID, bundle identifier,
    /// and a best-effort localized name.
    public static func capturableProcesses() throws(RecordingError) -> [SystemAudioProcess] {
      let objectIDs = try SystemAudioHAL.processObjectList()
      return objectIDs.map { objectID in
        let pid = SystemAudioHAL.pid(objectID: objectID)
        let name = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        return SystemAudioProcess(
          id: SystemAudioProcessObjectID(rawValue: objectID),
          processID: pid ?? -1,
          bundleIdentifier: SystemAudioHAL.bundleID(objectID: objectID),
          name: name,
        )
      }
    }
  }

  // MARK: - HAL plumbing

  /// Thin wrappers over the Core Audio HAL process-object properties used by the
  /// public discovery API. Mirrors the property-read style in `PlatformAudioBackend`.
  private enum SystemAudioHAL {
    private static var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    static func translate(processID: Int32) -> UInt32? {
      var pid = processID
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
      )
      var objectID = AudioObjectID(kAudioObjectUnknown)
      var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
      let status = unsafe withUnsafeMutablePointer(to: &pid) { pidPointer in
        unsafe AudioObjectGetPropertyData(
          systemObject,
          &address,
          UInt32(MemoryLayout<Int32>.size),
          pidPointer,
          &dataSize,
          &objectID,
        )
      }
      guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
      return objectID
    }

    static func processObjectList() throws(RecordingError) -> [AudioObjectID] {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
      )
      var dataSize: UInt32 = 0
      let sizeStatus = unsafe AudioObjectGetPropertyDataSize(
        systemObject,
        &address,
        0,
        nil,
        &dataSize,
      )
      guard sizeStatus == noErr else {
        throw RecordingError.systemAudioStartupFailure(
          sizeStatus,
          operation: "list process objects (size)",
        )
      }
      let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
      guard count > 0 else { return [] }
      var objectIDs = Array(repeating: AudioObjectID(0), count: count)
      let readStatus = unsafe objectIDs.withUnsafeMutableBytes { buffer in
        unsafe AudioObjectGetPropertyData(
          systemObject,
          &address,
          0,
          nil,
          &dataSize,
          buffer.baseAddress!,
        )
      }
      guard readStatus == noErr else {
        throw RecordingError.systemAudioStartupFailure(
          readStatus,
          operation: "list process objects",
        )
      }
      return objectIDs
    }

    static func pid(objectID: AudioObjectID) -> Int32? {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
      )
      var pid: Int32 = -1
      var dataSize = UInt32(MemoryLayout<Int32>.size)
      let status = unsafe AudioObjectGetPropertyData(
        objectID,
        &address,
        0,
        nil,
        &dataSize,
        &pid,
      )
      guard status == noErr else { return nil }
      return pid
    }

    static func bundleID(objectID: AudioObjectID) -> String? {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyBundleID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
      )
      var dataSize = UInt32(MemoryLayout<CFString?>.size)
      let rawValue = UnsafeMutableRawPointer.allocate(
        byteCount: Int(dataSize),
        alignment: MemoryLayout<CFString?>.alignment,
      )
      defer { unsafe rawValue.deallocate() }
      let status = unsafe AudioObjectGetPropertyData(
        objectID,
        &address,
        0,
        nil,
        &dataSize,
        rawValue,
      )
      guard status == noErr else { return nil }
      let value = unsafe rawValue.assumingMemoryBound(to: CFString?.self).pointee
      // Normalize a missing bundle identifier (the HAL reports it as an empty
      // string for processes without one) to `nil`.
      guard let bundleID = value as String?, !bundleID.isEmpty else { return nil }
      return bundleID
    }
  }
#endif
