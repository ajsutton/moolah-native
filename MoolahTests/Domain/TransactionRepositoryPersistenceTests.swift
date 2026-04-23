import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("TransactionRepository — Persistence")
struct TransactionRepositoryPersistenceTests {
  /// Shared fixture for `testUpdatePreservesAllFields`: a fully populated
  /// recurring transfer transaction with categoryId + earmarkId on one leg.
  private struct UpdateRoundTripFixture {
    let original: Transaction
    let date: Date
    let fromAccountId: UUID
    let toAccountId: UUID
    let categoryId: UUID
    let earmarkId: UUID
  }

  private static func makeUpdateRoundTripFixture() throws -> UpdateRoundTripFixture {
    let calendar = Calendar.current
    let fromAccountId = UUID()
    let toAccountId = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()
    let date = try #require(calendar.date(from: DateComponents(year: 2024, month: 3, day: 12)))
    let negSevenFifty = try #require(Decimal(string: "-750.00"))
    let sevenFifty = try #require(Decimal(string: "750.00"))

    let original = Transaction(
      date: date,
      payee: "Original Payee",
      notes: "Some notes",
      recurPeriod: .month,
      recurEvery: 2,
      legs: [
        TransactionLeg(
          accountId: fromAccountId, instrument: .defaultTestInstrument,
          quantity: negSevenFifty, type: .transfer,
          categoryId: categoryId, earmarkId: earmarkId),
        TransactionLeg(
          accountId: toAccountId, instrument: .defaultTestInstrument,
          quantity: sevenFifty, type: .transfer),
      ]
    )
    return UpdateRoundTripFixture(
      original: original, date: date,
      fromAccountId: fromAccountId, toAccountId: toAccountId,
      categoryId: categoryId, earmarkId: earmarkId)
  }

  @Test("update preserves all transaction fields")
  func testUpdatePreservesAllFields() async throws {
    let repository = try makeContractCloudKitTransactionRepository()
    let fixture = try Self.makeUpdateRoundTripFixture()
    let negSevenFifty = try #require(Decimal(string: "-750.00"))

    let created = try await repository.create(fixture.original)
    var updated = created
    updated.payee = "Updated Payee"
    let result = try await repository.update(updated)

    // Verify all fields match the updated transaction
    #expect(result.id == created.id)
    #expect(result.legs.allSatisfy { $0.type == .transfer })
    #expect(result.date == fixture.date)
    #expect(result.legs.count == 2)
    #expect(result.legs[0].accountId == fixture.fromAccountId)
    #expect(result.legs[1].accountId == fixture.toAccountId)
    #expect(result.legs[0].quantity == negSevenFifty)
    #expect(result.payee == "Updated Payee")
    #expect(result.notes == "Some notes")
    #expect(result.legs.contains(where: { $0.categoryId == fixture.categoryId }))
    #expect(result.legs.contains(where: { $0.earmarkId == fixture.earmarkId }))
    #expect(result.recurPeriod == .month)
    #expect(result.recurEvery == 2)

    // Verify persistence by fetching back from repository (scheduled filter needed since
    // the transaction has recurPeriod set, and the default filter excludes scheduled)
    let page = try await repository.fetch(
      filter: TransactionFilter(scheduled: true),
      page: 0,
      pageSize: 50
    )
    let fetched = try #require(page.transactions.first(where: { $0.id == created.id }))

    #expect(fetched.legs.allSatisfy { $0.type == .transfer })
    #expect(fetched.date == fixture.date)
    #expect(fetched.legs.count == 2)
    #expect(fetched.legs[0].accountId == fixture.fromAccountId)
    #expect(fetched.legs[1].accountId == fixture.toAccountId)
    #expect(fetched.legs[0].quantity == negSevenFifty)
    #expect(fetched.payee == "Updated Payee")
    #expect(fetched.notes == "Some notes")
    #expect(fetched.legs.contains(where: { $0.categoryId == fixture.categoryId }))
    #expect(fetched.legs.contains(where: { $0.earmarkId == fixture.earmarkId }))
    #expect(fetched.recurPeriod == .month)
    #expect(fetched.recurEvery == 2)
  }

  @Test("transfer creates with two legs")
  func testTransferCreatesTwoLegs() async throws {
    let repository = try makeContractCloudKitTransactionRepository()
    let fromAccount = UUID()
    let toAccount = UUID()
    let negFive = try #require(Decimal(string: "-5.00"))
    let five = try #require(Decimal(string: "5.00"))
    let transfer = Transaction(
      date: Date(),
      payee: "Transfer",
      legs: [
        TransactionLeg(
          accountId: fromAccount, instrument: .defaultTestInstrument,
          quantity: negFive, type: .transfer),
        TransactionLeg(
          accountId: toAccount, instrument: .defaultTestInstrument,
          quantity: five, type: .transfer),
      ]
    )

    let created = try await repository.create(transfer)
    #expect(created.legs.count == 2)
    #expect(created.isTransfer)
  }

  @Test("transactions are sorted by date descending")
  func testTransactionsSortedByDateDesc() async throws {
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makeContractTestTransactions())
    let page = try await repository.fetch(
      filter: TransactionFilter(),
      page: 0,
      pageSize: 50
    )

    for i in 0..<(page.transactions.count - 1) {
      #expect(
        page.transactions[i].date >= page.transactions[i + 1].date,
        "Transactions should be sorted by date descending"
      )
    }
  }
}
