import Foundation
import SwiftData
import Testing

@testable import Moolah

/// Pins the contract that `CloudKitAccountRepository.fetchAll` excludes legs
/// belonging to scheduled (recurring) transactions from each account's
/// positions. Phase 3 of #519 changes how that exclusion is implemented (push
/// the predicate into SwiftData so the driver doesn't materialise all of a
/// large profile's legs into Swift just to filter ~16 of them out), and this
/// test must keep passing across the change.
@Suite("AccountRepository — Scheduled Leg Exclusion")
struct AccountRepositoryNoSchedLegsTests {
  @Test("fetchAll excludes scheduled-transaction legs from account positions")
  func testFetchAllExcludesScheduledLegs() async throws {
    let accountId = UUID()
    let container = try TestModelContainer.create()
    let context = ModelContext(container)

    context.insert(
      AccountRecord.from(
        Account(
          id: accountId, name: "Test", type: .bank,
          instrument: .defaultTestInstrument)))

    // A scheduled (recurring) transaction. Its leg must NOT contribute.
    let scheduledTxnId = UUID()
    context.insert(
      TransactionRecord(
        id: scheduledTxnId, date: Date(), payee: "Scheduled",
        recurPeriod: RecurPeriod.month.rawValue, recurEvery: 1))
    context.insert(
      TransactionLegRecord.from(
        TransactionLeg(
          accountId: accountId, instrument: .defaultTestInstrument,
          quantity: -100, type: .expense),
        transactionId: scheduledTxnId, sortOrder: 0))

    // A non-scheduled transaction. Its leg contributes -25.
    let realTxnId = UUID()
    context.insert(TransactionRecord(id: realTxnId, date: Date(), payee: "Real"))
    context.insert(
      TransactionLegRecord.from(
        TransactionLeg(
          accountId: accountId, instrument: .defaultTestInstrument,
          quantity: -25, type: .expense),
        transactionId: realTxnId, sortOrder: 0))

    try context.save()

    let repository = CloudKitAccountRepository(modelContainer: container)
    let accounts = try await repository.fetchAll()
    let fetched = try #require(accounts.first { $0.id == accountId })
    let position = try #require(
      fetched.positions.first { $0.instrument == .defaultTestInstrument })
    #expect(position.quantity == -25)
  }

  @Test("fetchAll returns all legs when no transactions are scheduled")
  func testFetchAllReturnsAllLegsWhenNoneScheduled() async throws {
    let accountId = UUID()
    let container = try TestModelContainer.create()
    let context = ModelContext(container)

    context.insert(
      AccountRecord.from(
        Account(
          id: accountId, name: "Test", type: .bank,
          instrument: .defaultTestInstrument)))

    let txnId = UUID()
    context.insert(TransactionRecord(id: txnId, date: Date(), payee: "Real"))
    context.insert(
      TransactionLegRecord.from(
        TransactionLeg(
          accountId: accountId, instrument: .defaultTestInstrument,
          quantity: 500, type: .income),
        transactionId: txnId, sortOrder: 0))

    try context.save()

    let repository = CloudKitAccountRepository(modelContainer: container)
    let accounts = try await repository.fetchAll()
    let fetched = try #require(accounts.first { $0.id == accountId })
    let position = try #require(
      fetched.positions.first { $0.instrument == .defaultTestInstrument })
    #expect(position.quantity == 500)
  }
}
