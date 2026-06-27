// © GoodHatsLLC

#if os(macOS)
  import CoreAudio
  public import Foundation
  public import Tools

  public struct AudioInput: Hashable, Sendable, Identifiable, CustomStringConvertible, Comparable {
    public enum PreferenceError: AudioError {
      case unsupportedOperation

      public var description: String {
        "Audio input preference changes are not supported on this platform"
      }
    }

    public init(
      id: String = UUID().uuidString,
      name: String,
      type: InputType = .unknown,
      channelCount: ChannelCount = .mono,
      availableSources: [AudioSource] = [],
    ) {
      self.id = id
      self.name = name
      self.type = type
      self.channelCount = channelCount
      self.availableSources = availableSources
      selectedSource = availableSources.first
    }

    public let id: String
    public let name: String
    public let type: InputType
    public let channelCount: ChannelCount
    public let availableSources: [AudioSource]
    public let selectedSource: AudioSource?

    public var description: String {
      name
    }

    public var sources: [AudioSource] {
      availableSources
    }

    public var preferredSource: AudioSource? {
      selectedSource
    }

    public func set(preferredSource source: AudioSource?) throws(PreferenceError) {
      if let source, !availableSources.contains(source) {
        throw .unsupportedOperation
      }
    }

    public static func < (lhs: AudioInput, rhs: AudioInput) -> Bool {
      lhs.name < rhs.name
    }
  }

  extension AudioInput {
    public enum InputType: Hashable, Sendable {
      case unknown
      case continuityMicrophone
      case lineIn
      case builtInMic
      case headsetMic
      case bluetoothHFP
      case usbAudio
      case carAudio
      case virtual
      case PCI
      case fireWire
      case displayPort
      case AVB
      case thunderbolt

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
        }
      }

      init(coreAudioTransportType transportType: UInt32) {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
          self = .builtInMic
        case kAudioDeviceTransportTypeUSB:
          self = .usbAudio
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
          self = .bluetoothHFP
        case kAudioDeviceTransportTypeVirtual:
          self = .virtual
        case kAudioDeviceTransportTypePCI:
          self = .PCI
        case kAudioDeviceTransportTypeFireWire:
          self = .fireWire
        case kAudioDeviceTransportTypeDisplayPort:
          self = .displayPort
        case kAudioDeviceTransportTypeAVB:
          self = .AVB
        case kAudioDeviceTransportTypeThunderbolt:
          self = .thunderbolt
        case kAudioDeviceTransportTypeContinuityCaptureWired,
          kAudioDeviceTransportTypeContinuityCaptureWireless:
          self = .continuityMicrophone
        default:
          self = .unknown
        }
      }
    }
  }
#endif
