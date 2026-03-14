// © GoodHatsLLC

#if os(macOS)
  public struct AudioRouteChangeEvent: Sendable, Hashable {
    public init(userMessage: String = "Audio route changed") {
      self.userMessage = userMessage
    }

    public let userMessage: String
  }
#endif
