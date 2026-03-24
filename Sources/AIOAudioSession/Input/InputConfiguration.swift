// © GoodHatsLLC

public struct InputConfiguration: CustomStringConvertible,
  Hashable, Identifiable, Sendable
{
  public var description: String {
    "\(channels) \(sampleRate)"
  }

  public init(sampleRate: SampleRate, channels: ChannelCount) {
    self.sampleRate = sampleRate
    self.channels = channels
  }

  public var id: Self {
    self
  }

  public let sampleRate: SampleRate
  public let channels: ChannelCount
}
