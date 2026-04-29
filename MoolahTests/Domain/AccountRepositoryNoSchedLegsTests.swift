import Foundation
import Testing

@testable import Moolah

/// Pins the contract that `AccountRepository.fetchAll` excludes legs
/// belonging to scheduled (recurring) transactions from each account's
/// positions. The exclusion is implemented at the SQL layer; this test
/// must keep passing across any rewrite.
@Suite("AccountRepository — Scheduled Leg Exclusion")
struct AccountRepositoryNoSchedLegsTests {
  @Test("fetchAll excludes scheduled-transaction legs from account positions")
  func testFetchAllExcludesScheduledLegs() async throws {
    let accountId = UUID()
    let pair = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank,
          instrument: .defaultTestInstrument)
      ], in: pair.database)

    // A scheduled (recurring) transaction. Its leg must NOT contribute.
    let scheduled = Transaction(
      date: Date(),
      payee: "Scheduled",
      recurPeriod: .month,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .defaultTestInstrument,
          quantity: -100, type: .expense)
      ])
    // A non-scheduled transaction. Its leg contributes -25.
    let real = Transaction(
      date: Date(),
      payee: "Real",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .defaultTestInstrument,
          quantity: -25, type: .expense)
      ])
    TestBackend.seed(transactions: [scheduled, real], in: pair.database)

    let accounts = try await pair.backend.accounts.fetchAll()
    let fetched = try #require(accounts.first { $0.id == accountId })
    let position = try #require(
      fetched.positions.first { $0.instrument == .defaultTestInstrument })
    #expect(position.quantity == -25)
  }

  @Test("fetchAll returns all legs when no transactions are scheduled")
  func testFetchAllReturnsAllLegsWhenNoneScheduled() async throws {
    let accountId = UUID()
    let pair = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank,
          instrument: .defaultTestInstrument)
      ], in: pair.database)
    let txn = Transaction(
      date: Date(),
      payee: "Real",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .defaultTestInstrument,
          quantity: 500, type: .income)
      ])
    TestBackend.seed(transactions: [txn], in: pair.database)

    let accounts = try await pair.backend.accounts.fetchAll()
    let fetched = try #require(accounts.first { $0.id == accountId })
    let position = try #require(
      fetched.positions.first { $0.instrument == .defaultTestInstrument })
    #expect(position.quantity == 500)
  }
}
