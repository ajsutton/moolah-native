import Foundation
import SwiftData
import Testing

@testable import Moolah

/// Pagination depends on a deterministic order coming out of
/// `CloudKitTransactionRepository.fetch`. The repository must order results by
/// date descending, with `id` ascending as a stable tiebreaker so pages don't
/// reshuffle across calls when several transactions share a date.
///
/// These tests pin down the contract independently of the implementation, so
/// the perf rework in #517 (snapshotting sort keys to avoid SwiftData property
/// faults) can't accidentally regress ordering.
@Suite("TransactionRepository — Ordering")
struct TransactionRepositoryOrderingTests {
  @Test("scheduled fetch sorts ties by id ascending")
  func testScheduledTiesBreakById() async throws {
    let calendar = Calendar.current
    let sharedDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 1, day: 15)))
    let accountId = UUID()

    let idA = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000A"))
    let idB = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000B"))
    let idC = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000C"))
    let txnA = makeScheduled(id: idA, date: sharedDate, accountId: accountId, payee: "A")
    let txnB = makeScheduled(id: idB, date: sharedDate, accountId: accountId, payee: "B")
    let txnC = makeScheduled(id: idC, date: sharedDate, accountId: accountId, payee: "C")

    // Insert deliberately out-of-order so the test fails if we accidentally
    // rely on insertion order.
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: [txnC, txnA, txnB])

    let page = try await repository.fetch(
      filter: TransactionFilter(scheduled: .scheduledOnly),
      page: 0,
      pageSize: 50)

    #expect(page.transactions.map(\.id) == [idA, idB, idC])
  }

  @Test("scheduled fetch sorts by date descending then id ascending")
  func testScheduledOrderByDateDescThenId() async throws {
    let calendar = Calendar.current
    let earlyDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 1, day: 10)))
    let midDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 1, day: 15)))
    let lateDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 1, day: 20)))
    let accountId = UUID()

    let earlyId = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000E001"))
    let midAId = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1"))
    let midBId = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000B1"))
    let lateId = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000F1"))
    let early = makeScheduled(id: earlyId, date: earlyDate, accountId: accountId, payee: "early")
    let midA = makeScheduled(id: midAId, date: midDate, accountId: accountId, payee: "midA")
    let midB = makeScheduled(id: midBId, date: midDate, accountId: accountId, payee: "midB")
    let late = makeScheduled(id: lateId, date: lateDate, accountId: accountId, payee: "late")

    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: [midB, early, late, midA])

    let page = try await repository.fetch(
      filter: TransactionFilter(scheduled: .scheduledOnly),
      page: 0,
      pageSize: 50)

    #expect(page.transactions.map(\.id) == [lateId, midAId, midBId, earlyId])
  }

  @Test("pagination is stable across calls when dates collide")
  func testPaginationStableAcrossCallsOnSameDate() async throws {
    let calendar = Calendar.current
    let sharedDate = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 1, day: 15)))
    let accountId = UUID()

    // Twelve transactions on the same date, inserted in a scrambled order.
    var ids: [UUID] = []
    for index in 0..<12 {
      let suffix = String(format: "%012d", index)
      ids.append(try #require(UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")))
    }
    let scrambled = [9, 2, 7, 0, 11, 4, 1, 8, 3, 10, 5, 6].map { index in
      makeScheduled(
        id: ids[index], date: sharedDate, accountId: accountId, payee: "row\(index)")
    }
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: scrambled)

    let pageSize = 5
    var collected: [UUID] = []
    for page in 0..<3 {
      let result = try await repository.fetch(
        filter: TransactionFilter(scheduled: .scheduledOnly),
        page: page,
        pageSize: pageSize)
      collected.append(contentsOf: result.transactions.map(\.id))
    }

    #expect(collected == ids)
  }

  // MARK: - Fixture

  private func makeScheduled(
    id: UUID, date: Date, accountId: UUID, payee: String
  ) -> Transaction {
    Transaction(
      id: id,
      date: date,
      payee: payee,
      recurPeriod: .month,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .defaultTestInstrument,
          quantity: -10,
          type: .expense)
      ])
  }
}
