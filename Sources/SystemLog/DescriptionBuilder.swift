@resultBuilder
public struct DescriptionBuilder {

  public static func buildPartialBlock(first: [String]) -> [String] {
    first
  }

  public static func buildPartialBlock(accumulated: [String], next: [String]) -> [String] {
    accumulated + next
  }

  public static func buildFinalResult(_ component: [String]) -> String {
    component.joined(separator: "\n")
  }

  public static func buildBlock(_ components: String...) -> [String] {
    components
  }

  @_disfavoredOverload
  public static func buildExpression<T>(_ expression: T) -> [String] {
    [String(reflecting: expression)]
  }
  public static func buildExpression<T: CustomStringConvertible>(_ expression: T) -> [String] {
    [expression.description]
  }
}

extension String {
  public static func of(@DescriptionBuilder builder: () -> String) -> String {
    builder()
  }
}
