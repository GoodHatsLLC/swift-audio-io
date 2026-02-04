import AVFoundation

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
  }

  public static var recorderDefault: AudioSessionConfiguration {
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
      mode: .default,
      options: options,
      allowsHapticsAndSystemSoundsDuringRecording: true,
      prefersNoInterruptionsFromSystemAlerts: true,
      prefersInterruptionOnRouteDisconnect: false
    )
  }

  public static var playbackDefault: AudioSessionConfiguration {
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
