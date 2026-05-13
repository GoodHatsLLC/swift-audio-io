// © GoodHatsLLC

import Testing

@testable import Tools

struct StreamErasureTests {
  @Test
  func nonThrowingErasureFinishesWhenUpstreamFinishes() async {
    let source = AsyncSignalStream<Int>.makeStream(bufferingPolicy: .unbounded)
    let erased: AsyncSignalStream<Int> = .init(isolation: nil, source.stream)
    var iterator = erased.makeAsyncIterator()

    source.continuation.yield(1)
    #expect(await iterator.next() == 1)

    source.continuation.finish()
    #expect(await iterator.next() == nil)
  }

  @Test
  func throwingErasureFinishesWhenUpstreamFinishes() async throws {
    let source = AsyncThrowingSignalStream<Int>.makeStream(bufferingPolicy: .unbounded)
    let erased: AsyncThrowingSignalStream<Int> = .init(isolation: nil, source.stream)
    var iterator = erased.makeAsyncIterator()

    source.continuation.yield(1)
    #expect(try await iterator.next() == 1)

    source.continuation.finish()
    #expect(try await iterator.next() == nil)
  }
}
