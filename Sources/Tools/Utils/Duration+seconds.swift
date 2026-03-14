// © GoodHatsLLC

extension Duration {
  public var seconds: Double {
    self / Duration.seconds(1)
  }
}
