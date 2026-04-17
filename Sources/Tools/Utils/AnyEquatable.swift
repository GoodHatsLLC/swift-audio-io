/// Type-erased `Equatable` wrapper.
///
/// Equality is decided by a comparator captured at init time, while the
/// original `T` is still in scope. This sidesteps the fact that `any Equatable`
/// does not self-conform to `Equatable` (because `Equatable` has `Self`
/// requirements), so an `[any Equatable]` cannot be compared directly.
///
/// - Note: This wrapper makes **no** `Sendable` guarantee. If you need to send
///   erased equatable values across isolation boundaries, use
///   ``AnySendableEquatable`` instead.
public struct AnyEquatable: Equatable {
  private let elements: [Element]

  public init<T: Equatable>(_ value: T) {
    self.elements = [Element(value)]
  }

  public init<each T: Equatable>(of many: repeat each T) {
    var group: [Element] = []
    for value in repeat each many {
      group.append(Element(value))
    }
    self.elements = group
  }

  public static func == (lhs: AnyEquatable, rhs: AnyEquatable) -> Bool {
    lhs.elements == rhs.elements
  }
}

extension AnyEquatable {
  fileprivate struct Element: Equatable {
    let value: any Equatable
    let isEqualTo: (any Equatable) -> Bool

    init<T: Equatable>(_ value: T) {
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
