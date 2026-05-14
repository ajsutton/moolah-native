import Foundation
import Testing

@testable import Moolah

/// Contract tests for the `createMany(_:)` bulk-insert path on
/// `TransactionRepository`. Insertion is atomic: every input transaction
/// and its legs persist together, or — on any failure — none of them do.
/// Used by the CSV import pipeline.
@Suite("TransactionRepository — createMany contract")
struct CreateManyContractTests {

  @Test("createMany persists every transaction and its legs")
  func createManyPersistsEverything() async throws {
    let repository = try makeContractCloudKitTransactionRepository()
    let accountId = UUID()
    let inputs = (0..<5).map { index in
      Transaction(
        date: Date(),
        payee: "Payee \(index)",
        legs: [
          makeContractTestLeg(
            accountId: accountId,
            quantity: Decimal(-(index + 1) * 10),
            type: .expense)
        ])
    }

    let created = try await repository.createMany(inputs)

    #expect(created.count == inputs.count)
    #expect(created.map(\.id) == inputs.map(\.id))
    let fetched = try await repository.fetchAll(
      filter: TransactionFilter(accountId: accountId))
    let fetchedIds = Set(fetched.map(\.id))
    let inputIds = Set(inputs.map(\.id))
    #expect(fetchedIds == inputIds)
    #expect(fetched.allSatisfy { $0.legs.count == 1 })
  }

  @Test("createMany with empty input is a no-op and returns []")
  func createManyEmptyIsNoop() async throws {
    let repository = try makeContractCloudKitTransactionRepository()
    let result = try await repository.createMany([])
    #expect(result.isEmpty)
  }

  @Test("createMany returns the transactions in input order")
  func createManyPreservesInputOrder() async throws {
    let repository = try makeContractCloudKitTransactionRepository()
    let accountId = UUID()
    let inputs = ["A", "B", "C", "D"].map { payee in
      Transaction(
        date: Date(), payee: payee,
        legs: [
          makeContractTestLeg(accountId: accountId, quantity: -1, type: .expense)
        ])
    }

    let created = try await repository.createMany(inputs)

    #expect(created.map(\.payee) == ["A", "B", "C", "D"])
    #expect(created.map(\.id) == inputs.map(\.id))
  }
}
