#if canImport(AVFoundation)
  public import AVFoundation

  #if os(macOS)
    public typealias PlatformChannel = AudioChannelDescription
    extension PlatformChannel: @retroactive Hashable {
      public static func == (lhs: PlatformChannel, rhs: PlatformChannel) -> Bool {
        lhs.mChannelLabel == rhs.mChannelLabel
      }
      public func hash(into hasher: inout Hasher) {
        hasher.combine(mChannelLabel)
      }
      public var name: String {
        mChannelLabel.description
      }
      /// Description of the physical location of this channel.
      public var channelLabel: AudioChannelLabel {
        mChannelLabel
      }
    }
  #else
    public typealias PlatformChannel = AVAudioSessionChannelDescription
    extension PlatformChannel {
      public var name: String {
        channelName
      }

    }
  #endif

  public struct AudioChannel: Sendable, Hashable {
    let platform: PlatformChannel

    init(platform: PlatformChannel) {
      self.platform = platform
    }

    public var name: String {
      platform.name
    }
    /// Description of the physical location of this channel.
    public var channelLabel: AudioChannelLabel {
      platform.channelLabel
    }

    #if !os(macOS)

      /// A human-readable name for the channel.
      /// The UID (unique identifier) of the port owning the channel.
      public var owningInputID: String {
        platform.owningPortUID
      }
      /// The index of this channel in its owning port's array of channels.
      public var channelNumber: Int {
        platform.channelNumber
      }
    #endif

  }
#endif
