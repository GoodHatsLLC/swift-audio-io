#if canImport(AVFoundation)
import AVFoundation
import SystemLog

private let log = SystemLog.make()

/// A struct that provides information about the audio environment and allows for its configuration.
public struct AudioEnvironment: Sendable {
  /// Creates a new `AudioEnvironment` instance.
  ///
  /// - Parameters:
  ///   - session: The `AVAudioSession` to use. Defaults to the shared instance.
  ///   - notifications: The `Notifications` instance to use.
  public init(
    session: AVAudioSession = AVAudioSession.sharedInstance(),
    notifications: Notifications = Notifications()
  ) {
    self.session = session
    self.notifications = notifications
  }

  let session: AVAudioSession
  /// The notifications provided by the audio environment.
  public let notifications: Notifications

  /// The current audio input.
  public var input: AudioInput? {
    session.currentRoute.inputs.first.map {
      AudioInput(port: $0)
    }
  }

  /// Requests a specific audio input.
  ///
  /// - Parameter input: The audio input to request.
  /// - Throws: An error if the input cannot be set.
  public func request(input: AudioInput?) throws {
    try session.setPreferredInput(input?.platform)
  }

  /// The available audio inputs.
  public var availableInputs: [AudioInput] {
    (session.availableInputs ?? []).map { AudioInput(port: $0) }
  }

  /// The current audio source.
  public var source: AudioSource? {
    session.inputDataSource.map {
      AudioSource(avAudio: $0)
    }
  }

  /// The current sample rate.
  public var sampleRate: SampleRate {
    SampleRate(rawValue: session.sampleRate)
  }

  /// Requests a specific sample rate.
  ///
  /// The requested sample rate may not be honored. The actual sample rate is returned.
  ///
  /// - Parameter sampleRate: The sample rate to request.
  /// - Returns: The actual sample rate after the request.
  /// - Throws: An error if the sample rate cannot be set.
  public func request(sampleRate: SampleRate) throws -> SampleRate {
    try session.setPreferredSampleRate(sampleRate.platform)
    return self.sampleRate
  }

  /// Requests a specific audio source.
  ///
  /// - Parameter source: The audio source to request.
  /// - Throws: An error if the source cannot be set.
  public func request(source: AudioSource?) throws {
    // Always set the data source on the currently active input from the route.
    // This ensures we target the correct port in multi-input scenarios where
    // preferredInput might be nil (system defaults) or point to an inactive device.
    guard let activeInput = session.currentRoute.inputs.first else {
      throw NSError(
        domain: "AudioEnvironment",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "No active audio input to set data source on"]
      )
    }
    try activeInput.setPreferredDataSource(source?.platform)
  }

  /// The available audio sources.
  public var availableSources: [AudioSource] {
    if let sources = session.inputDataSources {
      return sources.map { AudioSource(avAudio: $0) }
    }
    return input?.availableSources ?? []
  }

}

extension AudioEnvironment {
  /// A struct that provides asynchronous streams for audio environment notifications.
  public struct Notifications: Sendable {
    /// Creates a new `Notifications` instance.
    ///
    /// - Parameter center: The `NotificationCenter` to use. Defaults to the default notification center.
    public init(center: NotificationCenter = .default) {
      self.center = center
    }

    private let center: NotificationCenter
    /// An asynchronous stream of audio session interruption notifications.
    public var interruption:
      AsyncStream<
        (type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions?)
      >
    {
      return AsyncStream<
        (type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions?)
      >(
        source: center.notifications(named: AVAudioSession.interruptionNotification),
        compactMap: {
          (notification: Notification) -> (
            type: AVAudioSession.InterruptionType,
            options: AVAudioSession.InterruptionOptions?
          )? in
          guard let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
          else {
            log.error(
              """
              interruption notification inapplicable:
              info: \(String(dump: notification.userInfo), privacy: .public)
              """)
            return nil
          }

          // Extract interruption options if available
          let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt
          let options = optionsValue.map { AVAudioSession.InterruptionOptions(rawValue: $0) }
          log.warning(
            """
              env, interruption notification: type=\(type.rawValue, privacy: .public), options=\(options.map{ "\($0.rawValue)" } ?? "nil", privacy: .public)
            """)
          return (type, options)
        }
      )
    }
    /// An asynchronous stream of audio session route change notifications.
    public var routeChange:
      AsyncStream<
        (reason: AVAudioSession.RouteChangeReason, previous: AVAudioSessionRouteDescription?)
      >
    {
      AsyncStream<
        (reason: AVAudioSession.RouteChangeReason, previous: AVAudioSessionRouteDescription?)
      >(
        source: center.notifications(named: AVAudioSession.routeChangeNotification),
        compactMap: { notification in
          log.warning("Environment: route change")
          if let info = notification.userInfo,
            let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
          {
            let previousRoute =
              info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            return (reason, previousRoute)
          } else {
            log.error(
              """
              routeChange notification inapplicable:
              info: \(String(dump: notification.userInfo), privacy: .public)
              """)
            return nil
          }
        }
      )
    }

    /// An asynchronous stream of notifications for when the available inputs change.
    public var availableInputsChanged: AsyncStream<Void> {
      if #available(iOS 26.0, *) {
        AsyncStream<Void>(
          source: center.notifications(named: AVAudioSession.availableInputsChangeNotification),
          map: { _ in () }
        )
      } else {
        AsyncStream<Void> { i in
          log.warning(
            "availableInputsChanged notifications are not available on this OS version"
          )
          i.finish()
        }
      }
    }

    /// An asynchronous stream of notifications for when the media services are lost.
    public var mediaServicesLost: AsyncStream<Void> {
      AsyncStream<Void>(
        source: center.notifications(named: AVAudioSession.mediaServicesWereLostNotification),
        map: { _ in
          log.warning("Environment: media services were lost")
          return ()
        }
      )
    }
    /// An asynchronous stream of notifications for when the media services are reset.
    public var mediaServicesReset: AsyncStream<Void> {
      AsyncStream<Void>(
        source: center.notifications(named: AVAudioSession.mediaServicesWereResetNotification),
        map: { _ in
          log.warning("Environment: media services were reset")
          return ()
        }
      )
    }
    /// An asynchronous stream of notifications for when secondary audio should be silenced.
    public var silenceSecondaryAudioHint: AsyncStream<Void> {
      AsyncStream<Void>(
        source: center.notifications(named: AVAudioSession.silenceSecondaryAudioHintNotification),
        map: { _ in
          log.warning("Environment: silence secondary audio")
          return ()
        }
      )
    }
  }
}

extension AVAudioSession.CategoryOptions {
  var description: String {
    if self == AVAudioSession.CategoryOptions.mixWithOthers {
      "mixWithOthers"
    } else if self == AVAudioSession.CategoryOptions.duckOthers {
      "duckOthers"
    } else if self == AVAudioSession.CategoryOptions.allowBluetoothHFP {
      "allowBluetoothHFP"
    } else if self == AVAudioSession.CategoryOptions.defaultToSpeaker {
      "defaultToSpeaker"
    } else if self == AVAudioSession.CategoryOptions.interruptSpokenAudioAndMixWithOthers {
      "interruptSpokenAudioAndMixWithOthers"
    } else if self == AVAudioSession.CategoryOptions.allowBluetoothA2DP {
      "allowBluetoothA2DP"
    } else if self == AVAudioSession.CategoryOptions.allowAirPlay {
      "allowAirPlay"
    } else if self == AVAudioSession.CategoryOptions.overrideMutedMicrophoneInterruption {
      "overrideMutedMicrophoneInterruption"
    } else {
      #if !targetEnvironment(macCatalyst)
      if #available(iOS 26.0, *), self == AVAudioSession.CategoryOptions.bluetoothHighQualityRecording
      {
        "bluetoothHighQualityRecording"
      } else {
        "unknown"
      }
      #else
      "unknown"
      #endif
    }
  }
}
#endif
