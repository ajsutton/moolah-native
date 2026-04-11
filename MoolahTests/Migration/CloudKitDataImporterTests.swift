import Foundation
import SwiftData
import Testing
import os

@testable import Moolah

/// Thread-safe progress step collector for testing.
private final class ProgressTracker: Sendable {
  private let _steps = OSAllocatedUnfairLock(initialState: [String]())

  func record(_ step: String) {
    _steps.withLock { $0.append(step) }
  }

  var steps: [String] {
    _steps.withLock { $0 }
  }
}

@Suite("CloudKitDataImporter")
struct CloudKitDataImporterTests {

  private let currency = Currency.defaultTestCurrency
  private let profileId = UUID()

  private func makeExportedData() -> ExportedData {
    let accountId = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()
    let budgetItemId = UUID()

    return ExportedData(
      accounts: [
        Account(
          id: accountId, name: "Checking", type: .bank,
          balance: MonetaryAmount(cents: 5000, currency: currency)
        ),
        Account(
          id: UUID(), name: "Savings", type: .bank,
          balance: MonetaryAmount(cents: 10000, currency: currency)
        ),
      ],
      categories: [
        Category(id: categoryId, name: "Food"),
        Category(id: UUID(), name: "Groceries", parentId: categoryId),
      ],
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday",
          balance: .zero(currency: currency),
          saved: .zero(currency: currency),
          spent: .zero(currency: currency)
        )
      ],
      earmarkBudgets: [
        earmarkId: [
          EarmarkBudgetItem(
            id: budgetItemId, categoryId: categoryId,
            amount: MonetaryAmount(cents: 5000, currency: currency)
          )
        ]
      ],
      transactions: [
        Transaction(
          type: .income, date: Date(), accountId: accountId,
          amount: MonetaryAmount(cents: 5000, currency: currency), payee: "Test"
        ),
        Transaction(
          type: .expense, date: Date(), accountId: accountId,
          amount: MonetaryAmount(cents: -1000, currency: currency),
          categoryId: categoryId, earmarkId: earmarkId
        ),
      ],
      investmentValues: [:]
    )
  }

  @Test("imports all exported data preserving UUIDs")
  func importPreservesIds() async throws {
    let container = try TestModelContainer.create()
    let exported = makeExportedData()
    let importer = CloudKitDataImporter(
      modelContainer: container,
      profileId: profileId,
      currencyCode: currency.code
    )

    let result = try await importer.importData(exported) { _ in }

    #expect(result.accountCount == 2)
    #expect(result.categoryCount == 2)
    #expect(result.earmarkCount == 1)
    #expect(result.budgetItemCount == 1)
    #expect(result.transactionCount == 2)
    #expect(result.investmentValueCount == 0)

    // Verify UUIDs are preserved
    let context = ModelContext(container)
    let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
    let exportedIds = Set(exported.accounts.map(\.id))
    let importedIds = Set(accounts.map(\.id))
    #expect(exportedIds == importedIds)

    // Verify categories preserve parent-child relationship
    let categories = try context.fetch(FetchDescriptor<CategoryRecord>())
    let child = categories.first { $0.parentId != nil }
    #expect(child != nil)
    #expect(child?.parentId == exported.categories.first?.id)
  }

  @Test("imports data scoped to profileId")
  func importScopedToProfile() async throws {
    let container = try TestModelContainer.create()
    let exported = makeExportedData()
    let importer = CloudKitDataImporter(
      modelContainer: container,
      profileId: profileId,
      currencyCode: currency.code
    )

    _ = try await importer.importData(exported) { _ in }

    let context = ModelContext(container)
    let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
    for account in accounts {
      #expect(account.profileId == profileId)
    }

    let transactions = try context.fetch(FetchDescriptor<TransactionRecord>())
    for txn in transactions {
      #expect(txn.profileId == profileId)
    }
  }

  @Test("stamps currencyCode on all monetary records")
  func importStampsCurrency() async throws {
    let container = try TestModelContainer.create()
    let exported = makeExportedData()
    let importer = CloudKitDataImporter(
      modelContainer: container,
      profileId: profileId,
      currencyCode: "USD"
    )

    _ = try await importer.importData(exported) { _ in }

    let context = ModelContext(container)
    let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
    for account in accounts {
      #expect(account.currencyCode == "USD")
    }
  }

  @Test("reports progress during import")
  func importReportsProgress() async throws {
    let container = try TestModelContainer.create()
    let exported = makeExportedData()
    let importer = CloudKitDataImporter(
      modelContainer: container,
      profileId: profileId,
      currencyCode: currency.code
    )

    let tracker = ProgressTracker()
    _ = try await importer.importData(exported) { progress in
      if case .importing(let step, _, _) = progress {
        tracker.record(step)
      }
    }

    let steps = tracker.steps
    #expect(steps.contains("categories"))
    #expect(steps.contains("accounts"))
    #expect(steps.contains("transactions"))
    #expect(steps.contains("saving"))
  }

  @Test("imports empty data successfully")
  func importEmpty() async throws {
    let container = try TestModelContainer.create()
    let exported = ExportedData(
      accounts: [],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [],
      investmentValues: [:]
    )
    let importer = CloudKitDataImporter(
      modelContainer: container,
      profileId: profileId,
      currencyCode: currency.code
    )

    let result = try await importer.importData(exported) { _ in }

    #expect(result.totalCount == 0)
  }
}
