// © GoodHatsLLC

public protocol TypeDescribable {
  static var typeDescription: String { get }
}

extension TypeDescribable {
  public static var typeDescription: String {
    String(describing: self.self)
  }
}
