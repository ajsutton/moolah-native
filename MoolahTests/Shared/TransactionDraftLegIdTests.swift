import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft preserves leg ids end-to-end")
struct TransactionDraftLegIdTests {

  @Test("init(from:) populates legId from each source leg")
  func initFromTransactionPopulatesLegId() {
    let leg = TransactionLeg(
      accountId: UUID(),
      instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(-10), type: .expense)
    let txn = Transaction(date: Date(), payee: "Coffee", legs: [leg])
    let draft = TransactionDraft(from: txn)
    #expect(draft.legDrafts.first?.legId == leg.id)
  }

  @Test("toTransaction(id:) round-trips legId for legs that came from a transaction")
  func toTransactionRoundTripsLegId() throws {
    let leg = TransactionLeg(
      accountId: UUID(),
      instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(-10), type: .expense)
    let txn = Transaction(date: Date(), payee: "Coffee", legs: [leg])
    let draft = TransactionDraft(from: txn)
    let rebuilt = try #require(draft.toTransaction(id: txn.id))
    #expect(rebuilt.legs.map(\.id) == [leg.id])
  }

  @Test("addLeg leaves the new draft's legId nil; saving allocates a fresh id")
  func addLegAllocatesFreshIdAtSave() throws {
    let leg = TransactionLeg(
      accountId: UUID(),
      instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(-10), type: .expense)
    let txn = Transaction(date: Date(), payee: "Coffee", legs: [leg])
    var draft = TransactionDraft(from: txn)
    // `isCustom` is the precondition for `toTransaction(id:)` to accept
    // a multi-leg non-transfer draft below; without it `isValid` would
    // refuse the second leg and `toTransaction` would return nil.
    draft.isCustom = true
    draft.addLeg(defaultAccountId: leg.accountId, instrument: Instrument.defaultTestInstrument)
    #expect(draft.legDrafts.last?.legId == nil)

    let rebuilt = try #require(draft.toTransaction(id: txn.id))
    #expect(rebuilt.legs.count == 2)
    #expect(rebuilt.legs[0].id == leg.id)
    #expect(rebuilt.legs[1].id != leg.id)
  }
}
