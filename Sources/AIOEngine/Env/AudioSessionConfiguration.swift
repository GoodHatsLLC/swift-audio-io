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
    // FIXME: this is a hack - it indicates all modes should be settable.
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
    #if os(iOS)
      #if targetEnvironment(macCatalyst)
        let options: AVAudioSession.CategoryOptions = []
      #else
        let options: AVAudioSession.CategoryOptions = [
          .defaultToSpeaker,
          .allowBluetoothA2DP,
          .allowAirPlay,
          .allowBluetoothHFP,
          .overrideMutedMicrophoneInterruption,
        ]
      #endif
    #elseif os(macOS)
      let options: AVAudioSession.CategoryOptions = [
        .allowBluetooth
      ]
    #else
      let options: AVAudioSession.CategoryOptions = []
    #endif

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
    #if os(iOS)
      #if targetEnvironment(macCatalyst)
        let options: AVAudioSession.CategoryOptions = []
      #else
        let options: AVAudioSession.CategoryOptions = [
          .allowAirPlay,
          .allowBluetoothA2DP,
        ]
      #endif
    #else
      let options: AVAudioSession.CategoryOptions = []
    #endif

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
