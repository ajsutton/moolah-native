import Foundation
import GRDB
import SwiftData
import Testing

@testable import Moolah

/// Correctness tests for the per-page bulk leg fetch introduced by issue #353.
/// The old implementation issued one `FetchDescriptor<TransactionLegRecord>` per
/// transaction in the page; the new implementation issues one `IN`-query and
/// groups legs in-memory by `transactionId`, preserving `sortOrder`.
@Suite("TransactionRepository bulk leg fetch")
struct TransactionRepositoryBulkFetchTests {

  @Test("page fetch groups legs by their own transaction preserving sortOrder")
  func testPageBulkFetchGroupsLegsPerTransaction() async throws {
    let accountId = UUID()
    let calendar = Calendar.current
    let baseDate = try #require(calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)))
    // 50 transactions, each with 3 legs bearing distinct, recognisable quantities
    // so any cross-contamination between transactions is immediately detectable.
    let transactions: [Transaction] = try (0..<50).map { txnIndex in
      let txnDate = try #require(calendar.date(byAdding: .day, value: txnIndex, to: baseDate))
      return Transaction(
        id: UUID(),
        date: txnDate,
        payee: "Txn \(txnIndex)",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .defaultTestInstrument,
            quantity: Decimal(txnIndex * 100 + 1), type: .expense),
          TransactionLeg(
            accountId: accountId, instrument: .defaultTestInstrument,
            quantity: Decimal(txnIndex * 100 + 2), type: .expense),
          TransactionLeg(
            accountId: accountId, instrument: .defaultTestInstrument,
            quantity: Decimal(txnIndex * 100 + 3), type: .expense),
        ]
      )
    }
    let repository = try makeRepository(initial: transactions)

    let page = try await repository.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 50)

    #expect(page.transactions.count == 50)
    for fetched in page.transactions {
      #expect(fetched.legs.count == 3, "transaction \(fetched.payee ?? "?") lost/gained legs")
      guard fetched.legs.count == 3 else { continue }
      #expect(fetched.legs[0].quantity < fetched.legs[1].quantity)
      #expect(fetched.legs[1].quantity < fetched.legs[2].quantity)
      // Every leg must belong to this transaction (txnIndex * 100 + {1,2,3}).
      let base = Int(truncating: fetched.legs[0].quantity as NSNumber) - 1
      #expect(base.isMultiple(of: 100), "leg 0 quantity doesn't fit the pattern")
      #expect(fetched.legs[1].quantity == Decimal(base + 2))
      #expect(fetched.legs[2].quantity == Decimal(base + 3))
    }
  }

  @Test("transactions with no legs come back with empty leg arrays")
  func testEmptyLegsDoNotBleedFromOthers() async throws {
    let accountId = UUID()
    let calendar = Calendar.current
    let baseDate = try #require(calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)))
    let populated = Transaction(
      id: UUID(),
      date: try #require(calendar.date(byAdding: .day, value: 1, to: baseDate)),
      payee: "Populated",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .defaultTestInstrument,
          quantity: Decimal(5), type: .expense)
      ]
    )
    let empty = Transaction(id: UUID(), date: baseDate, payee: "Empty", legs: [])
    let repository = try makeRepository(initial: [populated, empty])

    let page = try await repository.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 10)

    let fetchedEmpty = try #require(page.transactions.first(where: { $0.id == empty.id }))
    let fetchedPopulated = try #require(page.transactions.first(where: { $0.id == populated.id }))
    #expect(fetchedEmpty.legs.isEmpty)
    #expect(fetchedPopulated.legs.count == 1)
  }

  // MARK: - Helpers

  private func makeRepository(initial: [Transaction]) throws -> any TransactionRepository {
    let pair = try TestBackend.create()
    if !initial.isEmpty {
      TestBackend.seed(transactions: initial, in: pair.database)
    }
    return pair.backend.transactions
  }
}
