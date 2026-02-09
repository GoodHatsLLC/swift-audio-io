#if canImport(AVFoundation) && (!os(macOS) || targetEnvironment(macCatalyst))
  public import AVFoundation
  public import Tools

  public struct AudioInput: Hashable, Sendable, Identifiable, CustomStringConvertible {
    public enum PreferenceError: AudioError {
      case setPreferredSourceFailed(inputID: String, error: ErrorContext)

      public var description: String {
        switch self {
        case .setPreferredSourceFailed(let inputID, let error):
          "Failed to set preferred source for input \(inputID): \(error)"
        }
      }
    }

    public init(port: AVAudioSessionPortDescription) {
      self.port = port
    }

    public var description: String {
      port.portName
    }

    private let port: AVAudioSessionPortDescription
    public var avAudio: AVAudioSessionPortDescription { port }
    public var platform: AVAudioSessionPortDescription { port }
    public var sources: [AudioSource] {
      port.dataSources.orElse([]).map {
        AudioSource(avAudio: $0)
      }
    }

    public var selectedSource: AudioSource? {
      port.selectedDataSource.map(AudioSource.init(avAudio:))
    }

    public var availableSources: [AudioSource] {
      (port.dataSources ?? []).map(AudioSource.init(avAudio:))
    }

    public func set(preferredSource source: AudioSource?) throws(PreferenceError) {
      do {
        try port.setPreferredDataSource(preferredSource?.avAudio)
      } catch {
        throw .setPreferredSourceFailed(inputID: port.uid, error: ErrorContext(error))
      }
    }

    public var preferredSource: AudioSource? {
      port.preferredDataSource.map { AudioSource.init(avAudio: $0) }
    }

    public var channelCount: ChannelCount {
      (port.channels?.count ?? 1) > 1 ? .stereo : .mono
    }

    public var channels: [AudioChannel] {
      port.channels.orElse([]).map { AudioChannel.init(platform: $0) }
    }

    public var name: String {
      port.portName
    }

    public var id: String {
      port.uid
    }

    public var type: InputType {
      InputType(port.portType)
    }
  }

  extension AudioInput {
    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.port.uid == rhs.port.uid
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(port.uid)
    }
  }

  extension AudioInput: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
      lhs.name < rhs.name
    }
  }

  extension AudioInput {
    public enum InputType {
      public var systemImage: String {
        switch self {
        case .unknown:
          "questionmark.app.dashed"
        case .continuityMicrophone:
          "infinity"
        case .lineIn:
          "cable.connector.horizontal"
        case .builtInMic:
          "arrow.turn.up.forward.iphone"
        case .headsetMic:
          "headphones"
        case .bluetoothHFP:
          "airpods"
        case .usbAudio:
          "cable.connector"
        case .carAudio:
          "car"
        case .virtual:
          "sensor"
        #if !os(macOS)
          case .PCI:
            "laptopcomputer.and.arrow.down"
          case .fireWire:
            "cable.connector"
          case .displayPort:
            "cable.connector"
          case .AVB:
            "music.note.tv"
          case .thunderbolt:
            "bolt"
        #endif
        }
      }
      init(_ port: AVAudioSession.Port) {
        switch port {
        case .continuityMicrophone:
          self = .continuityMicrophone
        case .lineIn:
          self = .lineIn
        case .builtInMic:
          self = .builtInMic
        case .headsetMic:
          self = .headsetMic
        case .bluetoothHFP:
          self = .bluetoothHFP
        case .usbAudio:
          self = .usbAudio
        case .carAudio:
          self = .carAudio
        case .virtual:
          self = .virtual
        case .PCI:
          self = .PCI
        case .fireWire:
          self = .fireWire
        case .displayPort:
          self = .displayPort
        case .AVB:
          self = .AVB
        case .thunderbolt:
          self = .thunderbolt
        default:
          self = .unknown
        }
      }
      /// An unknown input type.
      case unknown
      /// Continuity microphone for appletv.
      case continuityMicrophone
      /// Line level input on a dock connector
      case lineIn
      /// Built-in microphone on an iOS device
      case builtInMic
      /// Microphone on a wired headset.
      /// Headset refers to an accessory that has headphone outputs paired with a microphone.
      case headsetMic
      /// Input on a Bluetooth Hands-Free Profile device
      case bluetoothHFP
      /// Input on a Universal Serial Bus device
      case usbAudio
      /// Input via Car Audio
      case carAudio
      /// Input that does not correspond to real audio hardware
      case virtual
      /// Input connected via the PCI (Peripheral Component Interconnect) bus
      case PCI
      /// Input connected via FireWire
      case fireWire
      /// Input connected via DisplayPort
      case displayPort
      /// Input connected via AVB (Audio Video Bridging)
      case AVB
      /// Input connected via Thunderbolt
      case thunderbolt
    }
  }
#endif  // canImport(AVFoundation)
