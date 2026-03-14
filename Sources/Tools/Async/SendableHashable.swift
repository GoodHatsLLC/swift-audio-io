// © GoodHatsLLC

struct SendableHashable {
  let underlying: any Hashable & Sendable
  @_disfavoredOverload
  init(_ underlying: any Hashable & Sendable) {
    self.init(underlying)
  }

  init(_ underlying: some Hashable & Sendable) {
    if let underlying = underlying as? SendableHashable {
      self = underlying
    } else {
      self.underlying = underlying
    }
  }
}

extension SendableHashable: Hashable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    AnyHashable(lhs.underlying) == AnyHashable(rhs.underlying)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(underlying)
  }
}

extension Hashable where Self: Sendable {
  func sendableHashable() -> SendableHashable {
    .init(self)
  }
}
