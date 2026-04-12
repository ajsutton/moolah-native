import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("Migration Integration")
@MainActor
struct MigrationIntegrationTests {

  private let currency = Currency.defaultTestCurrency

  /// Seeds a CloudKitBackend with realistic data for testing.
  /// Account balances are set to match the sum of their non-scheduled transactions,
  /// matching server behavior where balances are computed from transactions.
  private func makeSeededBackend() async throws -> CloudKitBackend {
    let (backend, _) = try TestBackend.create(currency: currency)

    // Accounts — set balance to match transaction totals below
    // Checking: +100,000 - 2,500 = 97,500
    let checking = try await backend.accounts.create(
      Account(
        name: "Checking", type: .bank,
        balance: MonetaryAmount(cents: 97_500, currency: currency)
      )
    )
    _ = try await backend.accounts.create(
      Account(name: "Credit Card", type: .creditCard, balance: .zero(currency: currency))
    )

    // Categories
    let food = try await backend.categories.create(Category(name: "Food"))
    _ = try await backend.categories.create(Category(name: "Groceries", parentId: food.id))
    _ = try await backend.categories.create(Category(name: "Transport"))

    // Earmarks
    let holiday = try await backend.earmarks.create(
      Earmark(name: "Holiday", balance: .zero(currency: currency))
    )
    try await backend.earmarks.setBudget(earmarkId: holiday.id, categoryId: food.id, amount: 5000)

    // Transactions (non-scheduled)
    _ = try await backend.transactions.create(
      Transaction(
        type: .income, date: Date(), accountId: checking.id,
        amount: MonetaryAmount(cents: 100_000, currency: currency), payee: "Employer"
      )
    )
    _ = try await backend.transactions.create(
      Transaction(
        type: .expense, date: Date(), accountId: checking.id,
        amount: MonetaryAmount(cents: -2500, currency: currency),
        payee: "Shop", categoryId: food.id, earmarkId: holiday.id
      )
    )

    // Scheduled transaction (excluded from balance computation)
    _ = try await backend.transactions.create(
      Transaction(
        type: .expense, date: Date(), accountId: checking.id,
        amount: MonetaryAmount(cents: -1000, currency: currency),
        payee: "Netflix", recurPeriod: .month, recurEvery: 1
      )
    )

    return backend
  }

  @Test("full migration round-trip: InMemory -> SwiftData -> verify")
  func fullMigration() async throws {
    let backend = try await makeSeededBackend()
    let container = try TestModelContainer.create()

    // 1. Export
    let exporter = DataExporter(backend: backend)
    let exported = try await exporter.export(
      profileLabel: "Test",
      currencyCode: currency.code,
      financialYearStartMonth: 7
    ) { _ in }

    // 2. Import
    let importer = CloudKitDataImporter(
      modelContainer: container,
      currencyCode: currency.code
    )
    let result = try await importer.importData(exported)

    #expect(result.accountCount == exported.accounts.count)
    #expect(result.categoryCount == exported.categories.count)
    #expect(result.earmarkCount == exported.earmarks.count)
    #expect(result.transactionCount == exported.transactions.count)

    // 3. Verify
    let verifier = MigrationVerifier()
    let verification = try await verifier.verify(
      exported: exported,
      modelContainer: container
    )

    #expect(verification.countMatch == true)
    #expect(verification.balanceMismatches.isEmpty)

    // 4. Read back through CloudKit repositories and compare
    let cloudBackend = CloudKitBackend(
      modelContainer: container,
      instrument: Instrument.fiat(code: currency.code),
      profileLabel: "Test"
    )
    let cloudAccounts = try await cloudBackend.accounts.fetchAll()
    #expect(cloudAccounts.count == exported.accounts.count)

    let cloudCategories = try await cloudBackend.categories.fetchAll()
    #expect(cloudCategories.count == exported.categories.count)

    let cloudEarmarks = try await cloudBackend.earmarks.fetchAll()
    #expect(cloudEarmarks.count == exported.earmarks.count)

    // Verify all non-scheduled transaction IDs match
    let cloudTxnPage = try await cloudBackend.transactions.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 1000
    )
    let cloudTxnIds = Set(cloudTxnPage.transactions.map(\.id))
    // Some transactions may be filtered by the default filter (scheduled=false),
    // so check that all non-scheduled exported IDs are present
    let nonScheduledExportedIds = Set(
      exported.transactions.filter { !$0.isScheduled }.map(\.id)
    )
    #expect(nonScheduledExportedIds.isSubset(of: cloudTxnIds))
  }

  @Test("migration preserves category hierarchy")
  func preservesCategoryHierarchy() async throws {
    let backend = try await makeSeededBackend()
    let container = try TestModelContainer.create()

    let exporter = DataExporter(backend: backend)
    let exported = try await exporter.export(
      profileLabel: "Test",
      currencyCode: currency.code,
      financialYearStartMonth: 7
    ) { _ in }

    let importer = CloudKitDataImporter(
      modelContainer: container,
      currencyCode: currency.code
    )
    _ = try await importer.importData(exported)

    // Read back and verify hierarchy
    let cloudBackend = CloudKitBackend(
      modelContainer: container,
      instrument: Instrument.fiat(code: currency.code),
      profileLabel: "Test"
    )
    let categories = try await cloudBackend.categories.fetchAll()
    let groceries = categories.first { $0.name == "Groceries" }
    let food = categories.first { $0.name == "Food" }

    #expect(groceries != nil)
    #expect(food != nil)
    #expect(groceries?.parentId == food?.id)
  }

  @Test("migration preserves earmark budgets")
  func preservesEarmarkBudgets() async throws {
    let backend = try await makeSeededBackend()
    let container = try TestModelContainer.create()

    let exporter = DataExporter(backend: backend)
    let exported = try await exporter.export(
      profileLabel: "Test",
      currencyCode: currency.code,
      financialYearStartMonth: 7
    ) { _ in }

    let importer = CloudKitDataImporter(
      modelContainer: container,
      currencyCode: currency.code
    )
    _ = try await importer.importData(exported)

    // Read back and verify budgets
    let cloudBackend = CloudKitBackend(
      modelContainer: container,
      instrument: Instrument.fiat(code: currency.code),
      profileLabel: "Test"
    )
    let earmarks = try await cloudBackend.earmarks.fetchAll()
    let holiday = earmarks.first { $0.name == "Holiday" }
    #expect(holiday != nil)

    let budgetItems = try await cloudBackend.earmarks.fetchBudget(earmarkId: holiday!.id)
    #expect(budgetItems.count == 1)
    #expect(budgetItems.first?.amount.cents == 5000)
  }
}
