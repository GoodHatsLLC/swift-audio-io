/// Type-erased `Equatable & Sendable` wrapper.
///
/// Same design as ``AnyEquatable`` (a comparator is captured at init time while
/// `T` is still in scope) but additionally requires every wrapped value to be
/// `Sendable`, so the wrapper itself is safe to cross isolation boundaries.
public struct AnySendableEquatable: Equatable, Sendable {
  private let elements: [Element]

  public init<T: Equatable & Sendable>(_ value: T) {
    self.elements = [Element(value)]
  }

  public init<each T: Equatable & Sendable>(of many: repeat each T) {
    var group: [Element] = []
    for value in repeat each many {
      group.append(Element(value))
    }
    self.elements = group
  }

  public static func == (lhs: AnySendableEquatable, rhs: AnySendableEquatable) -> Bool {
    lhs.elements == rhs.elements
  }
}

extension AnySendableEquatable {
  fileprivate struct Element: Equatable, Sendable {
    let value: any (Equatable & Sendable)
    let isEqualTo: @Sendable (any (Equatable & Sendable)) -> Bool

    init<T: Equatable & Sendable>(_ value: T) {
      self.value = value
      self.isEqualTo = { other in
        guard let other = other as? T else { return false }
        return other == value
      }
    }

    static func == (lhs: Element, rhs: Element) -> Bool {
      lhs.isEqualTo(rhs.value)
    }
  }
}

extension AnySendableEquatable {
  /// Bridge into the non-`Sendable` sibling when you need to mix values.
  public var erased: AnyEquatable {
    AnyEquatable(self)
  }
}
