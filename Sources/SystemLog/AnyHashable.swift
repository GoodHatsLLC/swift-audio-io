extension AnyHashable {
  init<each T: Hashable>(of many: repeat each T) {
    var group: [AnyHashable] = []
    for a in repeat each many {
      group.append(AnyHashable(a))
    }
    self = .init(group)
  }
}
