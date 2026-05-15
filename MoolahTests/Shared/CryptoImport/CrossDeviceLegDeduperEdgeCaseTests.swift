// MoolahTests/Shared/CryptoImport/CrossDeviceLegDeduperEdgeCaseTests.swift
import Foundation
import Testing

@testable import Moolah

/// Edge-case tests for `CrossDeviceLegDeduper`: mixed legs (one
/// duplicate + one unique), determinism across input ordering.
/// Convergence tests live in `CrossDeviceLegDeduperTests`.
@Suite("CrossDeviceLegDeduper — edge cases")
@MainActor
struct CrossDeviceLegDeduperEdgeCaseTests {
  private typealias Support = CrossDeviceLegDeduperTestSupport

  @Test("Mixed transaction (one duplicate leg + one unique leg) is skipped, not deleted")
  func mixedTransactionsAreSkipped() async throws {
    let setup = try Support.makeSetup()
    setup.seedAccount(Support.accountA)
    setup.seedAccount(Support.accountB)

    // Transaction A: one leg with the shared hash on account A.
    try await setup.create(
      Support.makeSingleLegTransaction(
        id: Support.txnA, accountId: Support.accountA, externalId: Support.hash))
    // Transaction B: one duplicate leg on account A AND one unique
    // leg on account B that is NOT shared with anyone — deleting B
    // would lose the unique leg.
    try await setup.create(
      Transaction(
        id: Support.txnB,
        date: Support.date,
        legs: [
          Support.makeLeg(
            accountId: Support.accountA,
            quantity: -1,
            externalId: Support.hash,
            type: .transfer),
          Support.makeLeg(
            accountId: Support.accountB,
            quantity: 5,
            externalId: "0xunique",
            type: .transfer),
        ]))

    let recording = RecordingTransactionRepository(wrapping: setup.backend.transactions)
    let deduper = CrossDeviceLegDeduper(transactions: recording)
    let collapsed = try await deduper.dedup(touchedExternalIds: [Support.hash])

    #expect(collapsed == 0)
    let stored = try await setup.backend.transactions.fetchAll(filter: .init())
    let storedIds = stored.map(\.id).sorted { $0.uuidString < $1.uuidString }
    #expect(storedIds == [Support.txnA, Support.txnB])
    let recordedDeletes = await recording.deletedIds
    #expect(recordedDeletes.isEmpty)
  }

  @Test("Same canonical wins regardless of input ordering")
  func deterministicAcrossInputOrder() async throws {
    // Build three transactions all sharing one (account, externalId)
    // group. The lex-min UUID (txnA) must always survive regardless
    // of which order the deduper sees them in.
    for ordering in Support.permutations(
      of: [Support.txnA, Support.txnB, Support.txnC])
    {
      let setup = try Support.makeSetup()
      setup.seedAccount(Support.accountA)
      for txnId in ordering {
        try await setup.create(
          Support.makeSingleLegTransaction(
            id: txnId, accountId: Support.accountA, externalId: Support.hash))
      }
      let deduper = CrossDeviceLegDeduper(transactions: setup.backend.transactions)
      let collapsed = try await deduper.dedup(touchedExternalIds: [Support.hash])
      #expect(collapsed == 2)
      let stored = try await setup.backend.transactions.fetchAll(filter: .init())
      #expect(stored.map(\.id) == [Support.txnA])
    }
  }
}
