import Foundation
import Testing

@testable import Moolah

@Suite("DismissedTransferPair")
struct DismissedTransferPairTests {
  @Test("id is order-independent for the same two ids")
  func deterministicId() {
    let idA = UUID()
    let idB = UUID()
    let first = DismissedTransferPair(transactionIds: [idA, idB], dismissedAt: Date())
    let second = DismissedTransferPair(transactionIds: [idB, idA], dismissedAt: Date())
    #expect(first.id == second.id)
  }

  @Test("covers a candidate pair regardless of order")
  func covers() {
    let idA = UUID()
    let idB = UUID()
    let pair = DismissedTransferPair(transactionIds: [idA, idB], dismissedAt: Date())
    #expect(pair.covers(idA, idB))
    #expect(pair.covers(idB, idA))
    #expect(!pair.covers(idA, UUID()))
  }
}
