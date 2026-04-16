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

@Suite("DataExporter")
struct DataExporterTests {

  private let instrument = Instrument.defaultTestInstrument

  private func makeBackendWithData() async throws -> CloudKitBackend {
    let (backend, _) = try TestBackend.create(instrument: instrument)

    // Create accounts
    _ = try await backend.accounts.create(
      Account(name: "Checking", type: .bank, instrument: instrument),
      openingBalance: nil
    )
    _ = try await backend.accounts.create(
      Account(name: "Savings", type: .bank, instrument: instrument),
      openingBalance: nil
    )
    let investmentAccount = try await backend.accounts.create(
      Account(name: "Portfolio", type: .investment, instrument: instrument),
      openingBalance: nil
    )

    // Create categories
    let food = try await backend.categories.create(Category(name: "Food"))
    _ = try await backend.categories.create(Category(name: "Groceries", parentId: food.id))

    // Create earmarks
    let holiday = try await backend.earmarks.create(
      Earmark(name: "Holiday", balance: .zero(instrument: instrument))
    )
    let budgetAmount = InstrumentAmount(quantity: Decimal(string: "50.00")!, instrument: instrument)
    try await backend.earmarks.setBudget(
      earmarkId: holiday.id, categoryId: food.id, amount: budgetAmount)

    // Create transactions
    let accounts = try await backend.accounts.fetchAll()
    let checking = accounts.first { $0.name == "Checking" }!
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Employer",
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: instrument,
            quantity: Decimal(string: "1000.00")!, type: .income
          )
        ]
      )
    )
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Shop",
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: instrument,
            quantity: Decimal(string: "-25.00")!, type: .expense,
            categoryId: food.id, earmarkId: holiday.id
          )
        ]
      )
    )

    // Create a scheduled transaction
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Streaming",
        recurPeriod: .month,
        recurEvery: 1,
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: instrument,
            quantity: Decimal(string: "-10.00")!, type: .expense
          )
        ]
      )
    )

    // Create investment values
    try await backend.investments.setValue(
      accountId: investmentAccount.id,
      date: Date(),
      value: InstrumentAmount(quantity: Decimal(string: "5000.00")!, instrument: instrument)
    )

    return backend
  }

  @Test("exports all data from InMemory backend")
  func exportAll() async throws {
    let backend = try await makeBackendWithData()
    let exporter = DataExporter(backend: backend)

    let progressSteps = ProgressTracker()
    let data = try await exporter.export(
      profileLabel: "Test",
      currencyCode: instrument.id,
      financialYearStartMonth: 7
    ) { progress in
      if case .downloading(let step) = progress {
        progressSteps.record(step)
      }
    }

    #expect(data.accounts.count == 3)
    #expect(data.categories.count == 2)
    #expect(data.earmarks.count == 1)
    #expect(data.transactions.count == 3)
    #expect(data.investmentValues.count == 1)

    // Verify progress was reported
    let steps = progressSteps.steps
    #expect(steps.contains("accounts"))
    #expect(steps.contains("categories"))
    #expect(steps.contains("transactions"))
  }

  @Test("exports earmark budgets keyed by earmark ID")
  func exportBudgets() async throws {
    let backend = try await makeBackendWithData()
    let exporter = DataExporter(backend: backend)

    let data = try await exporter.export(
      profileLabel: "Test",
      currencyCode: instrument.id,
      financialYearStartMonth: 7
    ) { _ in }

    let earmark = data.earmarks.first!
    let budgetItems = data.earmarkBudgets[earmark.id]
    #expect(budgetItems != nil)
    #expect(budgetItems!.count == 1)
    #expect(budgetItems!.first!.amount.quantity == Decimal(string: "50.00")!)
  }

  @Test("exports investment values per investment account")
  func exportInvestmentValues() async throws {
    let backend = try await makeBackendWithData()
    let exporter = DataExporter(backend: backend)

    let data = try await exporter.export(
      profileLabel: "Test",
      currencyCode: instrument.id,
      financialYearStartMonth: 7
    ) { _ in }

    let investmentAccount = data.accounts.first { $0.type == .investment }!
    let values = data.investmentValues[investmentAccount.id]
    #expect(values != nil)
    #expect(values!.count == 1)
    #expect(values!.first!.value.quantity == Decimal(string: "5000.00")!)
  }

  @Test("exports empty data from empty backend")
  func exportEmpty() async throws {
    let (backend, _) = try TestBackend.create()
    let exporter = DataExporter(backend: backend)

    let data = try await exporter.export(
      profileLabel: "Test",
      currencyCode: instrument.id,
      financialYearStartMonth: 7
    ) { _ in }

    #expect(data.accounts.isEmpty)
    #expect(data.categories.isEmpty)
    #expect(data.earmarks.isEmpty)
    #expect(data.transactions.isEmpty)
    #expect(data.investmentValues.isEmpty)
  }

  @Test("includes scheduled transactions in export")
  func exportIncludesScheduled() async throws {
    let backend = try await makeBackendWithData()
    let exporter = DataExporter(backend: backend)

    let data = try await exporter.export(
      profileLabel: "Test",
      currencyCode: instrument.id,
      financialYearStartMonth: 7
    ) { _ in }

    let scheduled = data.transactions.filter { $0.isScheduled }
    #expect(scheduled.count == 1)
    #expect(scheduled.first?.recurPeriod == .month)
  }
}
