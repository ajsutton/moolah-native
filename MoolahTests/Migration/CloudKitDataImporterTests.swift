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
@MainActor
struct CloudKitDataImporterTests {

  private let instrument = Instrument.defaultTestInstrument

  private func makeExportedData() -> ExportedData {
    let accountId = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()
    let budgetItemId = UUID()

    return ExportedData(
      accounts: [
        Account(
          id: accountId, name: "Checking", type: .bank,
          balance: InstrumentAmount(quantity: Decimal(string: "50.00")!, instrument: instrument)
        ),
        Account(
          id: UUID(), name: "Savings", type: .bank,
          balance: InstrumentAmount(quantity: Decimal(string: "100.00")!, instrument: instrument)
        ),
      ],
      categories: [
        Category(id: categoryId, name: "Food"),
        Category(id: UUID(), name: "Groceries", parentId: categoryId),
      ],
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday",
          balance: .zero(instrument: instrument),
          saved: .zero(instrument: instrument),
          spent: .zero(instrument: instrument)
        )
      ],
      earmarkBudgets: [
        earmarkId: [
          EarmarkBudgetItem(
            id: budgetItemId, categoryId: categoryId,
            amount: InstrumentAmount(quantity: Decimal(string: "50.00")!, instrument: instrument)
          )
        ]
      ],
      transactions: [
        Transaction(
          date: Date(),
          payee: "Test",
          legs: [
            TransactionLeg(
              accountId: accountId,
              instrument: instrument,
              quantity: Decimal(string: "50.00")!,
              type: .income
            )
          ]
        ),
        Transaction(
          date: Date(),
          legs: [
            TransactionLeg(
              accountId: accountId,
              instrument: instrument,
              quantity: Decimal(string: "-10.00")!,
              type: .expense,
              categoryId: categoryId,
              earmarkId: earmarkId
            )
          ]
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
      currencyCode: instrument.id
    )

    let result = try await importer.importData(exported)

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

  @Test("stamps instrumentId on transaction leg records")
  func importStampsInstrument() async throws {
    let container = try TestModelContainer.create()
    let exported = makeExportedData()
    let importer = CloudKitDataImporter(
      modelContainer: container,
      currencyCode: "USD"
    )

    _ = try await importer.importData(exported)

    let context = ModelContext(container)
    let legs = try context.fetch(FetchDescriptor<TransactionLegRecord>())
    #expect(!legs.isEmpty)
    for leg in legs {
      #expect(leg.instrumentId == instrument.id)
    }
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
      currencyCode: instrument.id
    )

    let result = try await importer.importData(exported)

    #expect(result.totalCount == 0)
  }
}
