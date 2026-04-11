import Foundation
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

@Suite("ServerDataExporter")
struct ServerDataExporterTests {

  private func makeBackendWithData() async throws -> InMemoryBackend {
    let currency = Currency.defaultTestCurrency
    let backend = InMemoryBackend(currency: currency)

    // Create accounts
    _ = try await backend.accounts.create(
      Account(name: "Checking", type: .bank, balance: .zero(currency: currency))
    )
    _ = try await backend.accounts.create(
      Account(name: "Savings", type: .bank, balance: .zero(currency: currency))
    )
    let investmentAccount = try await backend.accounts.create(
      Account(name: "Portfolio", type: .investment, balance: .zero(currency: currency))
    )

    // Create categories
    let food = try await backend.categories.create(Category(name: "Food"))
    _ = try await backend.categories.create(Category(name: "Groceries", parentId: food.id))

    // Create earmarks
    let holiday = try await backend.earmarks.create(
      Earmark(name: "Holiday", balance: .zero(currency: currency))
    )
    try await backend.earmarks.setBudget(earmarkId: holiday.id, categoryId: food.id, amount: 5000)

    // Create transactions
    let accounts = try await backend.accounts.fetchAll()
    let checking = accounts.first { $0.name == "Checking" }!
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

    // Create a scheduled transaction
    _ = try await backend.transactions.create(
      Transaction(
        type: .expense, date: Date(), accountId: checking.id,
        amount: MonetaryAmount(cents: -1000, currency: currency),
        payee: "Streaming", recurPeriod: .month, recurEvery: 1
      )
    )

    // Create investment values
    try await backend.investments.setValue(
      accountId: investmentAccount.id,
      date: Date(),
      value: MonetaryAmount(cents: 500_000, currency: currency)
    )

    return backend
  }

  @Test("exports all data from InMemory backend")
  func exportAll() async throws {
    let backend = try await makeBackendWithData()
    let exporter = ServerDataExporter(
      accountRepo: backend.accounts,
      categoryRepo: backend.categories,
      earmarkRepo: backend.earmarks,
      transactionRepo: backend.transactions,
      investmentRepo: backend.investments
    )

    let progressSteps = ProgressTracker()
    let data = try await exporter.export { progress in
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
    let exporter = ServerDataExporter(
      accountRepo: backend.accounts,
      categoryRepo: backend.categories,
      earmarkRepo: backend.earmarks,
      transactionRepo: backend.transactions,
      investmentRepo: backend.investments
    )

    let data = try await exporter.export { _ in }

    let earmark = data.earmarks.first!
    let budgetItems = data.earmarkBudgets[earmark.id]
    #expect(budgetItems != nil)
    #expect(budgetItems!.count == 1)
    #expect(budgetItems!.first!.amount.cents == 5000)
  }

  @Test("exports investment values per investment account")
  func exportInvestmentValues() async throws {
    let backend = try await makeBackendWithData()
    let exporter = ServerDataExporter(
      accountRepo: backend.accounts,
      categoryRepo: backend.categories,
      earmarkRepo: backend.earmarks,
      transactionRepo: backend.transactions,
      investmentRepo: backend.investments
    )

    let data = try await exporter.export { _ in }

    let investmentAccount = data.accounts.first { $0.type == .investment }!
    let values = data.investmentValues[investmentAccount.id]
    #expect(values != nil)
    #expect(values!.count == 1)
    #expect(values!.first!.value.cents == 500_000)
  }

  @Test("exports empty data from empty backend")
  func exportEmpty() async throws {
    let backend = InMemoryBackend()
    let exporter = ServerDataExporter(
      accountRepo: backend.accounts,
      categoryRepo: backend.categories,
      earmarkRepo: backend.earmarks,
      transactionRepo: backend.transactions,
      investmentRepo: backend.investments
    )

    let data = try await exporter.export { _ in }

    #expect(data.accounts.isEmpty)
    #expect(data.categories.isEmpty)
    #expect(data.earmarks.isEmpty)
    #expect(data.transactions.isEmpty)
    #expect(data.investmentValues.isEmpty)
  }

  @Test("includes scheduled transactions in export")
  func exportIncludesScheduled() async throws {
    let backend = try await makeBackendWithData()
    let exporter = ServerDataExporter(
      accountRepo: backend.accounts,
      categoryRepo: backend.categories,
      earmarkRepo: backend.earmarks,
      transactionRepo: backend.transactions,
      investmentRepo: backend.investments
    )

    let data = try await exporter.export { _ in }

    let scheduled = data.transactions.filter { $0.isScheduled }
    #expect(scheduled.count == 1)
    #expect(scheduled.first?.recurPeriod == .month)
  }
}
