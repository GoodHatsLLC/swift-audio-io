#if os(iOS)
  public import AVFoundation

  public struct AudioSessionConfiguration: Sendable, Hashable {
    public var category: AVAudioSession.Category
    public var mode: AVAudioSession.Mode
    public var options: AVAudioSession.CategoryOptions
    public var allowsHapticsAndSystemSoundsDuringRecording: Bool
    public var prefersNoInterruptionsFromSystemAlerts: Bool
    public var prefersInterruptionOnRouteDisconnect: Bool

    public init(
      category: AVAudioSession.Category,
      mode: AVAudioSession.Mode,
      options: AVAudioSession.CategoryOptions,
      allowsHapticsAndSystemSoundsDuringRecording: Bool = true,
      prefersNoInterruptionsFromSystemAlerts: Bool = true,
      prefersInterruptionOnRouteDisconnect: Bool = false
    ) {
      self.category = category
      self.mode = mode
      self.options = options
      self.allowsHapticsAndSystemSoundsDuringRecording = allowsHapticsAndSystemSoundsDuringRecording
      self.prefersNoInterruptionsFromSystemAlerts = prefersNoInterruptionsFromSystemAlerts
      self.prefersInterruptionOnRouteDisconnect = prefersInterruptionOnRouteDisconnect
      if mode != .measurement {
        UserDefaults.standard.setValue(false, forKey: StorageKey.useMeasurement)
      }
    }

    private enum StorageKey {
      static let useMeasurement = "aio.audio_session_conf.use_measurement"
    }

    public static var useMeasurement: Bool {
      get {
        UserDefaults.standard.bool(forKey: StorageKey.useMeasurement)
      }
      set {
        let current = useMeasurement
        if newValue != current {
          UserDefaults.standard.setValue(newValue, forKey: StorageKey.useMeasurement)
        }
      }
    }

    public static var recordingConfiguration: AudioSessionConfiguration {
      let options: AVAudioSession.CategoryOptions = [
        .defaultToSpeaker,
        .allowBluetoothA2DP,
        .allowAirPlay,
        .allowBluetoothHFP,
        .overrideMutedMicrophoneInterruption,
      ]

      return AudioSessionConfiguration(
        category: .playAndRecord,
        mode: useMeasurement ? .measurement : .default,
        options: options,
        allowsHapticsAndSystemSoundsDuringRecording: true,
        prefersNoInterruptionsFromSystemAlerts: true,
        prefersInterruptionOnRouteDisconnect: false
      )
    }

    public static var playbackConfiguration: AudioSessionConfiguration {
      let options: AVAudioSession.CategoryOptions = [
        .allowAirPlay,
        .allowBluetoothA2DP,
      ]

      return AudioSessionConfiguration(
        category: .playback,
        mode: .default,
        options: options,
        allowsHapticsAndSystemSoundsDuringRecording: false,
        prefersNoInterruptionsFromSystemAlerts: false,
        prefersInterruptionOnRouteDisconnect: false
      )
    }
  }

  extension AudioSessionConfiguration {
    public static func == (
      lhs: AudioSessionConfiguration,
      rhs: AudioSessionConfiguration
    ) -> Bool {
      lhs.category == rhs.category
        && lhs.mode == rhs.mode
        && lhs.options.rawValue == rhs.options.rawValue
        && lhs.allowsHapticsAndSystemSoundsDuringRecording
          == rhs.allowsHapticsAndSystemSoundsDuringRecording
        && lhs.prefersNoInterruptionsFromSystemAlerts
          == rhs.prefersNoInterruptionsFromSystemAlerts
        && lhs.prefersInterruptionOnRouteDisconnect
          == rhs.prefersInterruptionOnRouteDisconnect
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(category)
      hasher.combine(mode)
      hasher.combine(options.rawValue)
      hasher.combine(allowsHapticsAndSystemSoundsDuringRecording)
      hasher.combine(prefersNoInterruptionsFromSystemAlerts)
      hasher.combine(prefersInterruptionOnRouteDisconnect)
    }
  }
#else
  import Foundation

  /// Native macOS compatibility shape for call sites that configure audio session semantics.
  /// macOS does not expose `AVAudioSession`, so this type models equivalent intent-only values.
  public struct AudioSessionConfiguration: Sendable, Hashable {
    public struct Category: RawRepresentable, Sendable, Hashable {
      public var rawValue: String
      public init(rawValue: String) { self.rawValue = rawValue }
      public static let playAndRecord = Category(rawValue: "playAndRecord")
      public static let playback = Category(rawValue: "playback")
    }

    public struct Mode: RawRepresentable, Sendable, Hashable {
      public var rawValue: String
      public init(rawValue: String) { self.rawValue = rawValue }
      public static let `default` = Mode(rawValue: "default")
      public static let measurement = Mode(rawValue: "measurement")
    }

    public struct CategoryOptions: OptionSet, Sendable, Hashable {
      public let rawValue: UInt
      public init(rawValue: UInt) {
        self.rawValue = rawValue
      }
    }

    public var category: Category
    public var mode: Mode
    public var options: CategoryOptions
    public var allowsHapticsAndSystemSoundsDuringRecording: Bool
    public var prefersNoInterruptionsFromSystemAlerts: Bool
    public var prefersInterruptionOnRouteDisconnect: Bool

    public init(
      category: Category,
      mode: Mode,
      options: CategoryOptions,
      allowsHapticsAndSystemSoundsDuringRecording: Bool = true,
      prefersNoInterruptionsFromSystemAlerts: Bool = true,
      prefersInterruptionOnRouteDisconnect: Bool = false
    ) {
      self.category = category
      self.mode = mode
      self.options = options
      self.allowsHapticsAndSystemSoundsDuringRecording = allowsHapticsAndSystemSoundsDuringRecording
      self.prefersNoInterruptionsFromSystemAlerts = prefersNoInterruptionsFromSystemAlerts
      self.prefersInterruptionOnRouteDisconnect = prefersInterruptionOnRouteDisconnect
    }

    private enum StorageKey {
      static let useMeasurement = "aio.audio_session_conf.use_measurement"
    }

    public static var useMeasurement: Bool {
      get {
        UserDefaults.standard.bool(forKey: StorageKey.useMeasurement)
      }
      set {
        UserDefaults.standard.setValue(newValue, forKey: StorageKey.useMeasurement)
      }
    }

    public static var recordingConfiguration: AudioSessionConfiguration {
      AudioSessionConfiguration(
        category: .playAndRecord,
        mode: useMeasurement ? .measurement : .default,
        options: []
      )
    }

    public static var playbackConfiguration: AudioSessionConfiguration {
      AudioSessionConfiguration(
        category: .playback,
        mode: .default,
        options: []
      )
    }
  }
#endif
