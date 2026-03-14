// © GoodHatsLLC

enum Existential {}

extension Existential {
  /// Equate any two types. True only when both underlying types are `Equatable` and equal.
  static func isEqual(_ lhs: Any, _ rhs: Any) -> Bool? {
    _isEqual(lhs, rhs)
  }
}

func _isEqual(_ lhs: Any, _ rhs: Any) -> Bool? {
  (lhs as? any Equatable)?.isEqual(other: rhs)
}

extension Equatable {
  fileprivate func isEqual(other: Any) -> Bool {
    self == other as? Self
  }
}
