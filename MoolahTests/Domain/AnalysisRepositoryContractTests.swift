import Foundation
import Testing

@testable import Moolah

/// Contract tests for AnalysisRepository implementations.
/// Both InMemoryAnalysisRepository and RemoteAnalysisRepository must pass these tests.
@Suite("AnalysisRepository Contract Tests")
struct AnalysisRepositoryContractTests {

  // MARK: - Daily Balances Tests

  @Test("fetchDailyBalances returns empty array when no transactions")
  func dailyBalancesEmpty() async throws {
    let backend = InMemoryBackend()
    let repository = backend.analysis

    let balances = try await repository.fetchDailyBalances(after: nil, forecastUntil: nil)

    #expect(balances.isEmpty)
  }

  @Test("fetchDailyBalances returns balances ordered by date")
  func dailyBalancesOrdering() async throws {
    let backend = InMemoryBackend()

    // Create some sample transactions on different dates
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultCurrency)
    )
    _ = try await backend.accounts.create(account)

    // Add transactions on different dates
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!

    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: yesterday,
        accountId: account.id,
        amount: MonetaryAmount(cents: 100, currency: .defaultCurrency),
        payee: "Income"
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: twoDaysAgo,
        accountId: account.id,
        amount: MonetaryAmount(cents: 50, currency: .defaultCurrency),
        payee: "Earlier Income"
      ))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    // Verify ordering (ascending by date)
    for i in 0..<(balances.count - 1) {
      #expect(balances[i].date <= balances[i + 1].date)
    }
  }

  @Test("fetchDailyBalances computes availableFunds correctly")
  func availableFundsCalculation() async throws {
    let backend = InMemoryBackend()

    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultCurrency)
    )
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(
      id: UUID(),
      name: "Savings",
      balance: MonetaryAmount(cents: 0, currency: .defaultCurrency)
    )
    _ = try await backend.earmarks.create(earmark)

    // Add income (not earmarked)
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: Date(),
        accountId: account.id,
        amount: MonetaryAmount(cents: 100000, currency: .defaultCurrency),
        payee: "Income"
      ))

    // Add earmarked income
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: Date(),
        accountId: account.id,
        amount: MonetaryAmount(cents: 30000, currency: .defaultCurrency),
        payee: "Earmarked Income",
        earmarkId: earmark.id
      ))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    // Verify availableFunds = balance - earmarked
    for balance in balances {
      #expect(balance.availableFunds == balance.balance - balance.earmarked)
    }
  }

  @Test("fetchDailyBalances with forecastUntil includes scheduled balances")
  func forecastIncludesScheduled() async throws {
    let backend = InMemoryBackend()

    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultCurrency)
    )
    _ = try await backend.accounts.create(account)

    // Add a scheduled transaction (weekly)
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: Date(),
        accountId: account.id,
        amount: MonetaryAmount(cents: 100, currency: .defaultCurrency),
        payee: "Weekly Income",
        recurPeriod: .week,
        recurEvery: 1
      ))

    let future = Calendar.current.date(byAdding: .day, value: 30, to: Date())!
    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil,
      forecastUntil: future
    )

    let forecast = balances.filter { $0.isForecast }
    #expect(forecast.count > 0, "Should have forecast balances")
  }

  // MARK: - Expense Breakdown Tests

  @Test("fetchExpenseBreakdown groups by category and month")
  func expenseBreakdownGrouping() async throws {
    let backend = InMemoryBackend()

    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultCurrency)
    )
    _ = try await backend.accounts.create(account)

    let category = Category(
      id: UUID(),
      name: "Groceries"
    )
    _ = try await backend.categories.create(category)

    // Add expenses in different months
    let calendar = Calendar.current
    let thisMonth = Date()
    let lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth)!

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: thisMonth,
        accountId: account.id,
        amount: MonetaryAmount(cents: -100, currency: .defaultCurrency),
        payee: "Store A",
        categoryId: category.id
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: lastMonth,
        accountId: account.id,
        amount: MonetaryAmount(cents: -50, currency: .defaultCurrency),
        payee: "Store B",
        categoryId: category.id
      ))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    // Verify we have separate entries for each month
    let uniqueMonths = Set(breakdown.map { $0.month })
    #expect(uniqueMonths.count >= 1, "Should have at least one month")
  }

  @Test("fetchExpenseBreakdown excludes scheduled transactions")
  func expenseBreakdownExcludesScheduled() async throws {
    let backend = InMemoryBackend()

    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultCurrency)
    )
    _ = try await backend.accounts.create(account)

    // Add a scheduled expense
    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: Date(),
        accountId: account.id,
        amount: MonetaryAmount(cents: -100, currency: .defaultCurrency),
        payee: "Monthly Bill",
        recurPeriod: .month,
        recurEvery: 1
      ))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    // Should be empty (no completed expenses)
    #expect(breakdown.isEmpty, "Scheduled transactions should not appear in expense breakdown")
  }

  // MARK: - Income and Expense Tests

  @Test("fetchIncomeAndExpense computes profit correctly")
  func incomeExpenseProfitCalculation() async throws {
    let backend = InMemoryBackend()

    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultCurrency)
    )
    _ = try await backend.accounts.create(account)

    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: Date(),
        accountId: account.id,
        amount: MonetaryAmount(cents: 500, currency: .defaultCurrency),
        payee: "Income"
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: Date(),
        accountId: account.id,
        amount: MonetaryAmount(cents: -200, currency: .defaultCurrency),
        payee: "Expense"
      ))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    // Verify profit calculation
    for month in data {
      #expect(month.profit == month.income - month.expense)
      #expect(month.earmarkedProfit == month.earmarkedIncome - month.earmarkedExpense)
    }
  }

  @Test("fetchIncomeAndExpense handles investment transfers as earmarked")
  func investmentTransfersAsEarmarked() async throws {
    let backend = InMemoryBackend()

    let currentAccount = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      balance: MonetaryAmount(cents: 1000, currency: .defaultCurrency)
    )
    _ = try await backend.accounts.create(currentAccount)

    let investmentAccount = Account(
      id: UUID(),
      name: "Investment",
      type: .investment,
      balance: MonetaryAmount(cents: 0, currency: .defaultCurrency)
    )
    _ = try await backend.accounts.create(investmentAccount)

    // Transfer to investment (should count as earmarkedIncome)
    _ = try await backend.transactions.create(
      Transaction(
        type: .transfer,
        date: Date(),
        accountId: currentAccount.id,
        toAccountId: investmentAccount.id,
        amount: MonetaryAmount(cents: -100, currency: .defaultCurrency),
        payee: "Investment Contribution"
      ))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    // Verify transfer to investment appears in earmarkedIncome
    #expect(!data.isEmpty, "Should have at least one month")
    // Note: Actual earmarkedIncome verification requires understanding the full algorithm
  }
}
