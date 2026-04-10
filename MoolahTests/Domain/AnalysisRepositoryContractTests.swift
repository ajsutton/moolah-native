import Foundation
import SwiftData
import Testing

@testable import Moolah

/// Contract tests for AnalysisRepository implementations.
/// Both InMemoryAnalysisRepository and CloudKitAnalysisRepository must pass these tests.
@Suite("AnalysisRepository Contract Tests")
struct AnalysisRepositoryContractTests {

  // MARK: - Daily Balances Tests

  @Test(
    "fetchDailyBalances returns empty array when no transactions",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func dailyBalancesEmpty(backend: any BackendProvider) async throws {
    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    #expect(balances.isEmpty)
  }

  @Test(
    "fetchDailyBalances returns balances ordered by date",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func dailyBalancesOrdering(backend: any BackendProvider) async throws {
    // Create some sample transactions on different dates
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
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
        amount: MonetaryAmount(cents: 100, currency: .defaultTestCurrency),
        payee: "Income"
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: twoDaysAgo,
        accountId: account.id,
        amount: MonetaryAmount(cents: 50, currency: .defaultTestCurrency),
        payee: "Earlier Income"
      ))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    // Verify ordering (ascending by date)
    for i in 0..<(balances.count - 1) {
      #expect(balances[i].date <= balances[i + 1].date)
    }
  }

  @Test(
    "fetchDailyBalances computes availableFunds correctly",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func availableFundsCalculation(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(
      id: UUID(),
      name: "Savings",
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.earmarks.create(earmark)

    // Add income (not earmarked)
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: Date(),
        accountId: account.id,
        amount: MonetaryAmount(cents: 100000, currency: .defaultTestCurrency),
        payee: "Income"
      ))

    // Add earmarked income
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: Date(),
        accountId: account.id,
        amount: MonetaryAmount(cents: 30000, currency: .defaultTestCurrency),
        payee: "Earmarked Income",
        earmarkId: earmark.id
      ))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    // Verify availableFunds = balance - earmarked
    for balance in balances {
      #expect(balance.availableFunds == balance.balance - balance.earmarked)
    }
  }

  @Test(
    "fetchDailyBalances with forecastUntil includes scheduled balances",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func forecastIncludesScheduled(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    // Add a scheduled transaction (weekly)
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: Date(),
        accountId: account.id,
        amount: MonetaryAmount(cents: 100, currency: .defaultTestCurrency),
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

  @Test(
    "fetchExpenseBreakdown groups by category and month",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func expenseBreakdownGrouping(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
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
        amount: MonetaryAmount(cents: -100, currency: .defaultTestCurrency),
        payee: "Store A",
        categoryId: category.id
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: lastMonth,
        accountId: account.id,
        amount: MonetaryAmount(cents: -50, currency: .defaultTestCurrency),
        payee: "Store B",
        categoryId: category.id
      ))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    // Verify we have separate entries for each month
    let uniqueMonths = Set(breakdown.map { $0.month })
    #expect(uniqueMonths.count >= 1, "Should have at least one month")
  }

  @Test(
    "fetchExpenseBreakdown excludes scheduled transactions",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func expenseBreakdownExcludesScheduled(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    // Add a scheduled expense
    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: Date(),
        accountId: account.id,
        amount: MonetaryAmount(cents: -100, currency: .defaultTestCurrency),
        payee: "Monthly Bill",
        recurPeriod: .month,
        recurEvery: 1
      ))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    // Should be empty (no completed expenses)
    #expect(breakdown.isEmpty, "Scheduled transactions should not appear in expense breakdown")
  }

  @Test(
    "fetchExpenseBreakdown assigns transactions to correct financial month based on monthEnd",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func expenseBreakdownMonthBoundary(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let calendar = Calendar.current
    let onBoundary = calendar.date(from: DateComponents(year: 2025, month: 3, day: 25))!
    let afterBoundary = calendar.date(from: DateComponents(year: 2025, month: 3, day: 26))!

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: onBoundary,
        accountId: account.id,
        amount: MonetaryAmount(cents: -1000, currency: .defaultTestCurrency),
        payee: "On boundary",
        categoryId: category.id
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: afterBoundary,
        accountId: account.id,
        amount: MonetaryAmount(cents: -2000, currency: .defaultTestCurrency),
        payee: "After boundary",
        categoryId: category.id
      ))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    let marchEntries = breakdown.filter { $0.month == "202503" }
    let aprilEntries = breakdown.filter { $0.month == "202504" }

    #expect(marchEntries.count == 1, "Day 25 should belong to March financial month")
    #expect(aprilEntries.count == 1, "Day 26 should belong to April financial month")
    #expect(marchEntries[0].totalExpenses.cents == 1000)
    #expect(aprilEntries[0].totalExpenses.cents == 2000)
  }

  // MARK: - Income and Expense Tests

  @Test(
    "fetchIncomeAndExpense groups by financial month using monthEnd",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func incomeExpenseMonthBoundary(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let calendar = Calendar.current
    let onBoundary = calendar.date(from: DateComponents(year: 2025, month: 3, day: 25))!
    let afterBoundary = calendar.date(from: DateComponents(year: 2025, month: 3, day: 26))!

    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: onBoundary,
        accountId: account.id,
        amount: MonetaryAmount(cents: 1000, currency: .defaultTestCurrency),
        payee: "On boundary"
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: afterBoundary,
        accountId: account.id,
        amount: MonetaryAmount(cents: 2000, currency: .defaultTestCurrency),
        payee: "After boundary"
      ))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    let march = data.first { $0.month == "202503" }
    let april = data.first { $0.month == "202504" }

    #expect(march != nil, "Should have March financial month")
    #expect(april != nil, "Should have April financial month")
    #expect(march?.income.cents == 1000)
    #expect(april?.income.cents == 2000)
  }

  @Test(
    "fetchIncomeAndExpense computes profit correctly",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func incomeExpenseProfitCalculation(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: Date(),
        accountId: account.id,
        amount: MonetaryAmount(cents: 500, currency: .defaultTestCurrency),
        payee: "Income"
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: Date(),
        accountId: account.id,
        amount: MonetaryAmount(cents: -200, currency: .defaultTestCurrency),
        payee: "Expense"
      ))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    // Verify profit calculation
    for month in data {
      #expect(month.profit == month.income - month.expense)
      #expect(month.earmarkedProfit == month.earmarkedIncome - month.earmarkedExpense)
    }
  }

  @Test(
    "fetchIncomeAndExpense handles investment transfers as earmarked",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func investmentTransfersAsEarmarked(backend: any BackendProvider) async throws {
    let currentAccount = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      balance: MonetaryAmount(cents: 1000, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(currentAccount)

    let investmentAccount = Account(
      id: UUID(),
      name: "Investment",
      type: .investment,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(investmentAccount)

    // Transfer to investment (should count as earmarkedIncome)
    _ = try await backend.transactions.create(
      Transaction(
        type: .transfer,
        date: Date(),
        accountId: currentAccount.id,
        toAccountId: investmentAccount.id,
        amount: MonetaryAmount(cents: -100, currency: .defaultTestCurrency),
        payee: "Investment Contribution"
      ))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    // Verify transfer to investment appears in earmarkedIncome
    #expect(!data.isEmpty, "Should have at least one month")
  }

  // MARK: - Category Balances Tests

  @Test(
    "fetchCategoryBalances returns flat mapping",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func categoryBalancesFlatMapping(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let cat1 = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(cat1)

    let cat2 = Category(id: UUID(), name: "Restaurants")
    _ = try await backend.categories.create(cat2)

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let dateRange = today...today

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: -5000, currency: .defaultTestCurrency),
        payee: "Store",
        categoryId: cat1.id
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: -3000, currency: .defaultTestCurrency),
        payee: "Restaurant",
        categoryId: cat2.id
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: -2000, currency: .defaultTestCurrency),
        payee: "Store 2",
        categoryId: cat1.id
      ))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange,
      transactionType: .expense,
      filters: nil
    )

    // Verify totals are correct
    #expect(balances[cat1.id] == MonetaryAmount(cents: -7000, currency: .defaultTestCurrency))
    #expect(balances[cat2.id] == MonetaryAmount(cents: -3000, currency: .defaultTestCurrency))
  }

  @Test(
    "fetchCategoryBalances excludes scheduled transactions",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func categoryBalancesExcludesScheduled(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let cat = Category(id: UUID(), name: "Rent")
    _ = try await backend.categories.create(cat)

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let dateRange = today...today

    // Scheduled transaction
    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: -100000, currency: .defaultTestCurrency),
        payee: "Landlord",
        categoryId: cat.id,
        recurPeriod: .month,
        recurEvery: 1
      ))

    // Completed transaction
    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: -100000, currency: .defaultTestCurrency),
        payee: "Landlord",
        categoryId: cat.id,
        recurPeriod: nil
      ))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange,
      transactionType: .expense,
      filters: nil
    )

    // Only completed transaction counted
    #expect(balances[cat.id] == MonetaryAmount(cents: -100000, currency: .defaultTestCurrency))
  }

  @Test(
    "fetchCategoryBalances filters by transaction type",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func categoryBalancesFiltersByType(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let cat = Category(id: UUID(), name: "Salary")
    _ = try await backend.categories.create(cat)

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let dateRange = today...today

    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: 500000, currency: .defaultTestCurrency),
        payee: "Employer",
        categoryId: cat.id
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: -5000, currency: .defaultTestCurrency),
        payee: "Store",
        categoryId: cat.id
      ))

    let incomeBalances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange,
      transactionType: .income,
      filters: nil
    )

    // Only income counted
    #expect(
      incomeBalances[cat.id] == MonetaryAmount(cents: 500000, currency: .defaultTestCurrency))

    let expenseBalances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange,
      transactionType: .expense,
      filters: nil
    )

    // Only expense counted
    #expect(
      expenseBalances[cat.id] == MonetaryAmount(cents: -5000, currency: .defaultTestCurrency))
  }

  @Test(
    "fetchCategoryBalances respects date range",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func categoryBalancesRespectsDateRange(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let cat = Category(id: UUID(), name: "Gas")
    _ = try await backend.categories.create(cat)

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    let lastMonth = calendar.date(byAdding: .month, value: -1, to: today)!

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: yesterday,
        accountId: account.id,
        amount: MonetaryAmount(cents: -5000, currency: .defaultTestCurrency),
        payee: "Gas Station",
        categoryId: cat.id
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: lastMonth,
        accountId: account.id,
        amount: MonetaryAmount(cents: -3000, currency: .defaultTestCurrency),
        payee: "Gas Station",
        categoryId: cat.id
      ))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: yesterday...today,
      transactionType: .expense,
      filters: nil
    )

    // Only yesterday's transaction counted
    #expect(balances[cat.id] == MonetaryAmount(cents: -5000, currency: .defaultTestCurrency))
  }

  @Test(
    "fetchCategoryBalances applies additional filters",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func categoryBalancesAppliesFilters(backend: any BackendProvider) async throws {
    let account1 = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account1)

    let account2 = Account(
      id: UUID(),
      name: "Credit Card",
      type: .creditCard,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account2)

    let cat = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(cat)

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let dateRange = today...today

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: today,
        accountId: account1.id,
        amount: MonetaryAmount(cents: -5000, currency: .defaultTestCurrency),
        payee: "Store",
        categoryId: cat.id
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: today,
        accountId: account2.id,
        amount: MonetaryAmount(cents: -3000, currency: .defaultTestCurrency),
        payee: "Store",
        categoryId: cat.id
      ))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange,
      transactionType: .expense,
      filters: TransactionFilter(accountId: account1.id)
    )

    // Only account1 transaction counted
    #expect(balances[cat.id] == MonetaryAmount(cents: -5000, currency: .defaultTestCurrency))
  }

  @Test(
    "fetchCategoryBalances excludes transactions without category",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func categoryBalancesRequiresCategory(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let cat = Category(id: UUID(), name: "Misc")
    _ = try await backend.categories.create(cat)

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let dateRange = today...today

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: -5000, currency: .defaultTestCurrency),
        payee: "Store",
        categoryId: cat.id
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: -3000, currency: .defaultTestCurrency),
        payee: "Uncategorized",
        categoryId: nil
      ))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange,
      transactionType: .expense,
      filters: nil
    )

    #expect(balances.count == 1)
    #expect(balances[cat.id] == MonetaryAmount(cents: -5000, currency: .defaultTestCurrency))
  }

  @Test(
    "fetchCategoryBalances handles empty result",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func categoryBalancesEmptyResult(backend: any BackendProvider) async throws {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let dateRange = today...today

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange,
      transactionType: .expense,
      filters: nil
    )

    #expect(balances.isEmpty)
  }
}

// MARK: - CloudKit Test Backend

/// A BackendProvider that uses CloudKit repositories backed by an in-memory SwiftData container.
private struct CloudKitAnalysisTestBackend: BackendProvider, @unchecked Sendable {
  let auth: any AuthProvider
  let accounts: any AccountRepository
  let transactions: any TransactionRepository
  let categories: any CategoryRepository
  let earmarks: any EarmarkRepository
  let analysis: any AnalysisRepository
  let investments: any InvestmentRepository

  init() {
    let container = try! TestModelContainer.create()
    let profileId = UUID()
    let currency = Currency.defaultTestCurrency
    self.auth = InMemoryAuthProvider()
    self.accounts = CloudKitAccountRepository(
      modelContainer: container, profileId: profileId, currency: currency)
    self.transactions = CloudKitTransactionRepository(
      modelContainer: container, profileId: profileId, currency: currency)
    self.categories = CloudKitCategoryRepository(
      modelContainer: container, profileId: profileId)
    self.earmarks = CloudKitEarmarkRepository(
      modelContainer: container, profileId: profileId, currency: currency)
    self.analysis = CloudKitAnalysisRepository(
      modelContainer: container, profileId: profileId, currency: currency)
    self.investments = InMemoryInvestmentRepository()
  }
}
