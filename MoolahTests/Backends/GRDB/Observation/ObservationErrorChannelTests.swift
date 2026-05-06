import Foundation
import Testing

@testable import Moolah

@Suite("ObservationErrorChannel")
struct ObservationErrorChannelTests {

  @Test("surfaceAndFinish yields error then completes stream in one call")
  func surfaceAndFinishYieldsAndCompletes() async {
    let channel = ObservationErrorChannel()
    var iterator = channel.stream.makeAsyncIterator()
    let testError = NSError(domain: "test", code: 42)

    await channel.surfaceAndFinish(testError)

    let surfaced = await iterator.next()
    #expect((surfaced as NSError?)?.code == 42)

    let next = await iterator.next()
    #expect(next == nil)  // stream completed
  }

  @Test("after surfaceAndFinish, further calls are no-ops")
  func subsequentCallsNoOp() async {
    let channel = ObservationErrorChannel()
    var iterator = channel.stream.makeAsyncIterator()
    await channel.surfaceAndFinish(NSError(domain: "first", code: 1))
    _ = await iterator.next()
    _ = await iterator.next()  // completion
    await channel.surfaceAndFinish(NSError(domain: "second", code: 2))
    // No new emission should appear on the iterator (stream already finished).
  }
}
