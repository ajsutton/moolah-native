import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("MigrationVerifier")
struct MigrationVerifierTests {

  private let currency = Currency.defaultTestCurrency
  private let profileId = UUID()

  @Test("verification passes when counts and balances match")
  func countsMatch() async throws {
    let container = try TestModelContainer.create()
    let accountId = UUID()

    let exported = ExportedData(
      accounts: [
        Account(
          id: accountId, name: "Checking", type: .bank,
          balance: MonetaryAmount(cents: 5000, currency: currency)
        )
      ],
      categories: [Category(name: "Food")],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [
        Transaction(
          type: .income, date: Date(), accountId: accountId,
          amount: MonetaryAmount(cents: 5000, currency: currency)
        )
      ],
      investmentValues: [:]
    )

    // Import the data
    let importer = CloudKitDataImporter(
      modelContainer: container,
      profileId: profileId,
      currencyCode: currency.code
    )
    _ = try await importer.importData(exported) { _ in }

    // Verify
    let verifier = MigrationVerifier()
    let result = try await verifier.verify(
      exported: exported,
      modelContainer: container,
      profileId: profileId
    )

    #expect(result.countMatch == true)
    #expect(result.balanceMismatches.isEmpty)
    #expect(result.expectedCounts.accounts == 1)
    #expect(result.actualCounts.accounts == 1)
  }

  @Test("verification fails when transaction count mismatches")
  func countMismatch() async throws {
    let container = try TestModelContainer.create()
    let accountId = UUID()

    // Export claims 2 transactions, but we only import 1
    let exported = ExportedData(
      accounts: [
        Account(
          id: accountId, name: "Checking", type: .bank,
          balance: .zero(currency: currency)
        )
      ],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [
        Transaction(
          type: .income, date: Date(), accountId: accountId,
          amount: MonetaryAmount(cents: 1000, currency: currency)
        ),
        Transaction(
          type: .expense, date: Date(), accountId: accountId,
          amount: MonetaryAmount(cents: -500, currency: currency)
        ),
      ],
      investmentValues: [:]
    )

    // Import only 1 transaction manually
    let context = ModelContext(container)
    context.insert(
      AccountRecord(
        id: accountId, profileId: profileId, name: "Checking", type: "bank",
        currencyCode: currency.code
      )
    )
    context.insert(
      TransactionRecord(
        profileId: profileId, type: "income", date: Date(),
        accountId: accountId, amount: 1000, currencyCode: currency.code
      )
    )
    try context.save()

    let verifier = MigrationVerifier()
    let result = try await verifier.verify(
      exported: exported,
      modelContainer: container,
      profileId: profileId
    )

    #expect(result.countMatch == false)
    #expect(result.expectedCounts.transactions == 2)
    #expect(result.actualCounts.transactions == 1)
  }

  @Test("balance verification catches mismatches")
  func balanceMismatch() async throws {
    let container = try TestModelContainer.create()
    let accountId = UUID()

    // Server says balance is 5000, but imported transactions sum to 3000
    let exported = ExportedData(
      accounts: [
        Account(
          id: accountId, name: "Checking", type: .bank,
          balance: MonetaryAmount(cents: 5000, currency: currency)
        )
      ],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [
        Transaction(
          type: .income, date: Date(), accountId: accountId,
          amount: MonetaryAmount(cents: 3000, currency: currency)
        )
      ],
      investmentValues: [:]
    )

    let importer = CloudKitDataImporter(
      modelContainer: container,
      profileId: profileId,
      currencyCode: currency.code
    )
    _ = try await importer.importData(exported) { _ in }

    let verifier = MigrationVerifier()
    let result = try await verifier.verify(
      exported: exported,
      modelContainer: container,
      profileId: profileId
    )

    #expect(result.countMatch == false)
    #expect(result.balanceMismatches.count == 1)
    #expect(result.balanceMismatches.first?.accountName == "Checking")
    #expect(result.balanceMismatches.first?.serverBalance == 5000)
    #expect(result.balanceMismatches.first?.localBalance == 3000)
  }

  @Test("scheduled transactions excluded from balance computation")
  func scheduledExcludedFromBalance() async throws {
    let container = try TestModelContainer.create()
    let accountId = UUID()

    let exported = ExportedData(
      accounts: [
        Account(
          id: accountId, name: "Checking", type: .bank,
          balance: MonetaryAmount(cents: 5000, currency: currency)
        )
      ],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [
        Transaction(
          type: .income, date: Date(), accountId: accountId,
          amount: MonetaryAmount(cents: 5000, currency: currency)
        ),
        // Scheduled transaction should not affect balance
        Transaction(
          type: .expense, date: Date(), accountId: accountId,
          amount: MonetaryAmount(cents: -1000, currency: currency),
          recurPeriod: .month, recurEvery: 1
        ),
      ],
      investmentValues: [:]
    )

    let importer = CloudKitDataImporter(
      modelContainer: container,
      profileId: profileId,
      currencyCode: currency.code
    )
    _ = try await importer.importData(exported) { _ in }

    let verifier = MigrationVerifier()
    let result = try await verifier.verify(
      exported: exported,
      modelContainer: container,
      profileId: profileId
    )

    // Balance should match since scheduled txns are excluded
    #expect(result.countMatch == true)
    #expect(result.balanceMismatches.isEmpty)
  }
}
