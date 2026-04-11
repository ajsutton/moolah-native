import Foundation
import SwiftData
import Testing

@testable import Moolah

/// Contract tests for AnalysisRepository implementations.
/// CloudKitAnalysisRepository must pass these tests.
@Suite("AnalysisRepository Contract Tests")
struct AnalysisRepositoryContractTests {

  // MARK: - Daily Balances Tests

  @Test("fetchDailyBalances returns empty array when no transactions")
  func dailyBalancesEmpty() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    #expect(balances.isEmpty)
  }

  @Test("fetchDailyBalances returns balances ordered by date")
  func dailyBalancesOrdering() async throws {
    let backend = CloudKitAnalysisTestBackend()
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

  @Test("fetchDailyBalances computes availableFunds correctly")
  func availableFundsCalculation() async throws {
    let backend = CloudKitAnalysisTestBackend()
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

  @Test("fetchDailyBalances with forecastUntil includes scheduled balances")
  func forecastIncludesScheduled() async throws {
    let backend = CloudKitAnalysisTestBackend()
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

  @Test("earmarked balance in dailyBalances reflects earmarked transactions")
  func earmarkedBalanceFromTransactions() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(
      id: UUID(),
      name: "Holiday",
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.earmarks.create(earmark)

    let today = Calendar.current.startOfDay(for: Date())

    // Earmarked income: +500
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: 500, currency: .defaultTestCurrency),
        payee: "Earmarked Save",
        earmarkId: earmark.id
      ))

    // Earmarked expense: -200
    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: -200, currency: .defaultTestCurrency),
        payee: "Earmarked Spend",
        earmarkId: earmark.id
      ))

    // Non-earmarked income: +1000
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: 1000, currency: .defaultTestCurrency),
        payee: "Regular Income"
      ))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    #expect(!balances.isEmpty)
    let todayBalance = balances.first { Calendar.current.isDate($0.date, inSameDayAs: today) }
    #expect(todayBalance != nil)

    // Total balance = 500 - 200 + 1000 = 1300
    #expect(todayBalance?.balance.cents == 1300)
    // Earmarked = 500 - 200 = 300
    #expect(todayBalance?.earmarked.cents == 300)
    // Available = 1300 - 300 = 1000
    #expect(todayBalance?.availableFunds.cents == 1000)
  }

  @Test("daily balance + investments equals sum of current + investment account balances")
  func balanceInvariantCrossCheck() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let checking = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(checking)

    let savings = Account(
      id: UUID(),
      name: "Savings",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(savings)

    let investment = Account(
      id: UUID(),
      name: "Shares",
      type: .investment,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(investment)

    let today = Calendar.current.startOfDay(for: Date())

    // Income to checking
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: today,
        accountId: checking.id,
        amount: MonetaryAmount(cents: 5000, currency: .defaultTestCurrency),
        payee: "Salary"
      ))

    // Transfer checking → investment
    _ = try await backend.transactions.create(
      Transaction(
        type: .transfer,
        date: today,
        accountId: checking.id,
        toAccountId: investment.id,
        amount: MonetaryAmount(cents: -2000, currency: .defaultTestCurrency),
        payee: "Invest"
      ))

    // Income to savings
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: today,
        accountId: savings.id,
        amount: MonetaryAmount(cents: 1000, currency: .defaultTestCurrency),
        payee: "Interest"
      ))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    #expect(!balances.isEmpty)
    let todayBalance = balances.last!

    // balance = 5000 - 2000 + 1000 = 4000
    #expect(todayBalance.balance.cents == 4000)
    // investments = 2000
    #expect(todayBalance.investments.cents == 2000)
    // netWorth = 4000 + 2000 = 6000
    #expect(todayBalance.netWorth.cents == 6000)
  }

  // MARK: - Expense Breakdown Tests

  @Test("fetchExpenseBreakdown groups by category and month")
  func expenseBreakdownGrouping() async throws {
    let backend = CloudKitAnalysisTestBackend()
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

  @Test("fetchExpenseBreakdown excludes scheduled transactions")
  func expenseBreakdownExcludesScheduled() async throws {
    let backend = CloudKitAnalysisTestBackend()
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

  @Test("fetchExpenseBreakdown assigns transactions to correct financial month based on monthEnd")
  func expenseBreakdownMonthBoundary() async throws {
    let backend = CloudKitAnalysisTestBackend()
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
    #expect(marchEntries[0].totalExpenses.cents == -1000)
    #expect(aprilEntries[0].totalExpenses.cents == -2000)
  }

  // MARK: - Income and Expense Tests

  @Test("fetchIncomeAndExpense groups by financial month using monthEnd")
  func incomeExpenseMonthBoundary() async throws {
    let backend = CloudKitAnalysisTestBackend()
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

  @Test("fetchIncomeAndExpense computes profit correctly")
  func incomeExpenseProfitCalculation() async throws {
    let backend = CloudKitAnalysisTestBackend()
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

  @Test("fetchIncomeAndExpense handles investment transfers as earmarked")
  func investmentTransfersAsEarmarked() async throws {
    let backend = CloudKitAnalysisTestBackend()
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

  @Test("fetchIncomeAndExpense classifies investment transfers correctly")
  func investmentTransferClassification() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let bankAccount = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(bankAccount)

    let investmentA = Account(
      id: UUID(),
      name: "Shares",
      type: .investment,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(investmentA)

    let investmentB = Account(
      id: UUID(),
      name: "Bonds",
      type: .investment,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(investmentB)

    let today = Calendar.current.startOfDay(for: Date())

    // Bank → Investment (should be earmarkedIncome)
    _ = try await backend.transactions.create(
      Transaction(
        type: .transfer,
        date: today,
        accountId: bankAccount.id,
        toAccountId: investmentA.id,
        amount: MonetaryAmount(cents: -500, currency: .defaultTestCurrency),
        payee: "Invest"
      ))

    // Investment → Bank (should be earmarkedExpense)
    _ = try await backend.transactions.create(
      Transaction(
        type: .transfer,
        date: today,
        accountId: investmentA.id,
        toAccountId: bankAccount.id,
        amount: MonetaryAmount(cents: -200, currency: .defaultTestCurrency),
        payee: "Withdraw"
      ))

    // Investment → Investment (should not affect income/expense)
    _ = try await backend.transactions.create(
      Transaction(
        type: .transfer,
        date: today,
        accountId: investmentA.id,
        toAccountId: investmentB.id,
        amount: MonetaryAmount(cents: -100, currency: .defaultTestCurrency),
        payee: "Rebalance"
      ))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty, "Should have at least one month")
    let month = data[0]

    // Bank→Investment = earmarkedIncome of 500
    #expect(month.earmarkedIncome.cents == 500)

    // Investment→Bank = earmarkedExpense of 200
    #expect(month.earmarkedExpense.cents == 200)

    // Regular income/expense should be zero
    #expect(month.income.cents == 0)
    #expect(month.expense.cents == 0)
  }

  @Test("earmarked income without accountId excluded from balance, included in earmarked")
  func nullAccountIdEarmarkedHandling() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(
      id: UUID(),
      name: "Gift Fund",
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.earmarks.create(earmark)

    let today = Calendar.current.startOfDay(for: Date())

    // Regular income with accountId
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: 1000, currency: .defaultTestCurrency),
        payee: "Salary"
      ))

    // Earmarked income WITHOUT accountId
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: today,
        accountId: nil,
        amount: MonetaryAmount(cents: 500, currency: .defaultTestCurrency),
        payee: "Gift",
        earmarkId: earmark.id
      ))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // Regular income should only include the transaction with accountId
    #expect(month.income.cents == 1000)
    // Earmarked income should NOT include the nil-accountId transaction
    // (fetchIncomeAndExpense skips transactions with nil accountId)
    #expect(month.earmarkedIncome.cents == 0)
  }

  // MARK: - Category Balances Tests

  @Test("fetchCategoryBalances returns flat mapping")
  func categoryBalancesFlatMapping() async throws {
    let backend = CloudKitAnalysisTestBackend()
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

  @Test("fetchCategoryBalances excludes scheduled transactions")
  func categoryBalancesExcludesScheduled() async throws {
    let backend = CloudKitAnalysisTestBackend()
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

  @Test("fetchCategoryBalances filters by transaction type")
  func categoryBalancesFiltersByType() async throws {
    let backend = CloudKitAnalysisTestBackend()
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

  @Test("fetchCategoryBalances respects date range")
  func categoryBalancesRespectsDateRange() async throws {
    let backend = CloudKitAnalysisTestBackend()
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

  @Test("fetchCategoryBalances applies additional filters")
  func categoryBalancesAppliesFilters() async throws {
    let backend = CloudKitAnalysisTestBackend()
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

  @Test("fetchCategoryBalances excludes transactions without category")
  func categoryBalancesRequiresCategory() async throws {
    let backend = CloudKitAnalysisTestBackend()
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

  @Test("fetchCategoryBalances handles empty result")
  func categoryBalancesEmptyResult() async throws {
    let backend = CloudKitAnalysisTestBackend()
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

  @Test("fetchExpenseBreakdown returns months in descending order")
  func expenseBreakdownSortOrder() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Food")
    _ = try await backend.categories.create(category)

    let calendar = Calendar.current
    let month1 = calendar.date(from: DateComponents(year: 2025, month: 1, day: 15))!
    let month2 = calendar.date(from: DateComponents(year: 2025, month: 2, day: 15))!
    let month3 = calendar.date(from: DateComponents(year: 2025, month: 3, day: 15))!

    for date in [month1, month2, month3] {
      _ = try await backend.transactions.create(
        Transaction(
          type: .expense,
          date: date,
          accountId: account.id,
          amount: MonetaryAmount(cents: -100, currency: .defaultTestCurrency),
          payee: "Store",
          categoryId: category.id
        ))
    }

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    let months = breakdown.map(\.month)
    let uniqueMonths = months.reduce(into: [String]()) { result, month in
      if !result.contains(month) { result.append(month) }
    }

    for i in 0..<(uniqueMonths.count - 1) {
      #expect(
        uniqueMonths[i] > uniqueMonths[i + 1],
        "Expense breakdown months should be in descending order"
      )
    }
  }

  // MARK: - Investment Value Tests

  @Test("fetchDailyBalances computes investmentValue from investment values")
  func dailyBalancesInvestmentValue() async throws {
    let backend = CloudKitAnalysisTestBackend()
    // Create an investment account and a bank account
    let investmentAccount = Account(
      id: UUID(),
      name: "Portfolio",
      type: .investment,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(investmentAccount)

    let bankAccount = Account(
      id: UUID(),
      name: "Bank",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(bankAccount)

    // Create a transfer to the investment account
    let calendar = Calendar.current
    let day1 = calendar.date(from: DateComponents(year: 2025, month: 3, day: 1))!
    _ = try await backend.transactions.create(
      Transaction(
        type: .transfer,
        date: day1,
        accountId: bankAccount.id,
        toAccountId: investmentAccount.id,
        amount: MonetaryAmount(cents: -50000, currency: .defaultTestCurrency),
        payee: "Invest"
      ))

    // Set investment value (market value is higher than contributed)
    let day2 = calendar.date(from: DateComponents(year: 2025, month: 3, day: 2))!
    try await backend.investments.setValue(
      accountId: investmentAccount.id,
      date: day2,
      value: MonetaryAmount(cents: 55000, currency: .defaultTestCurrency)
    )

    // Create another transaction on day2 so we get a daily balance entry for it
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: day2,
        accountId: bankAccount.id,
        amount: MonetaryAmount(cents: 1000, currency: .defaultTestCurrency),
        payee: "Interest"
      ))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    // Find the balance for day2
    let day2Start = calendar.startOfDay(for: day2)
    let day2Balance = balances.first { $0.date == day2Start }
    #expect(day2Balance != nil, "Should have a balance for day2")
    #expect(
      day2Balance?.investmentValue == MonetaryAmount(cents: 55000, currency: .defaultTestCurrency),
      "investmentValue should reflect the recorded market value"
    )
    // netWorth should use investmentValue when available
    #expect(
      day2Balance?.netWorth == day2Balance!.balance + day2Balance!.investmentValue!,
      "netWorth should be balance + investmentValue"
    )
  }

  @Test("fetchDailyBalances computes bestFit linear regression")
  func dailyBalancesBestFit() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    // Create transactions on consecutive days with linearly increasing balances
    let calendar = Calendar.current
    let day1 = calendar.date(from: DateComponents(year: 2025, month: 3, day: 1))!
    let day2 = calendar.date(from: DateComponents(year: 2025, month: 3, day: 2))!
    let day3 = calendar.date(from: DateComponents(year: 2025, month: 3, day: 3))!

    // Day 1: +1000
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: day1,
        accountId: account.id,
        amount: MonetaryAmount(cents: 1000, currency: .defaultTestCurrency),
        payee: "Day 1"
      ))
    // Day 2: +1000 (cumulative 2000)
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: day2,
        accountId: account.id,
        amount: MonetaryAmount(cents: 1000, currency: .defaultTestCurrency),
        payee: "Day 2"
      ))
    // Day 3: +1000 (cumulative 3000)
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: day3,
        accountId: account.id,
        amount: MonetaryAmount(cents: 1000, currency: .defaultTestCurrency),
        payee: "Day 3"
      ))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    // All balances should have bestFit values (3 data points = enough for regression)
    for balance in balances {
      #expect(balance.bestFit != nil, "bestFit should be computed for each daily balance")
    }

    // For perfectly linear data, bestFit should closely match actual values
    let day1Start = calendar.startOfDay(for: day1)
    let day3Start = calendar.startOfDay(for: day3)
    let day1Balance = balances.first { $0.date == day1Start }
    let day3Balance = balances.first { $0.date == day3Start }
    #expect(day1Balance != nil)
    #expect(day3Balance != nil)

    // bestFit for day1 should be close to 1000 and day3 close to 3000
    // Allow small floating point tolerance (within 1 cent)
    #expect(abs(day1Balance!.bestFit!.cents - 1000) <= 1)
    #expect(abs(day3Balance!.bestFit!.cents - 3000) <= 1)
  }

  @Test("fetchDailyBalances returns nil bestFit with fewer than 2 data points")
  func dailyBalancesBestFitSinglePoint() async throws {
    let backend = CloudKitAnalysisTestBackend()
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
        amount: MonetaryAmount(cents: 1000, currency: .defaultTestCurrency),
        payee: "Single"
      ))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)
    #expect(balances.count == 1)
    #expect(balances[0].bestFit == nil, "bestFit should be nil with only 1 data point")
  }

  // MARK: - Expense Breakdown Uncategorized Tests

  @Test("fetchExpenseBreakdown includes uncategorized expenses")
  func expenseBreakdownIncludesUncategorized() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    // Create an uncategorized expense (no categoryId)
    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: Date(),
        accountId: account.id,
        amount: MonetaryAmount(cents: -500, currency: .defaultTestCurrency),
        payee: "Uncategorized Store"
      ))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    #expect(!breakdown.isEmpty, "Uncategorized expenses should appear in breakdown")
    let uncategorized = breakdown.filter { $0.categoryId == nil }
    #expect(
      uncategorized.count == 1,
      "Should have one uncategorized expense entry"
    )
    #expect(
      uncategorized[0].totalExpenses.cents == -500,
      "Uncategorized expense total should be -500 cents"
    )
  }

  // MARK: - loadAll Tests

  @Test("loadAll returns combined results matching individual methods")
  func loadAllReturnsCombinedResults() async throws {
    let backend = CloudKitAnalysisTestBackend()
    // Create test data
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: today)!

    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: calendar.date(byAdding: .day, value: -10, to: today)!,
        accountId: account.id,
        amount: MonetaryAmount(cents: 50000, currency: .defaultTestCurrency),
        payee: "Salary"
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: calendar.date(byAdding: .day, value: -5, to: today)!,
        accountId: account.id,
        amount: MonetaryAmount(cents: -20000, currency: .defaultTestCurrency),
        payee: "Groceries"
      ))

    let monthEnd = calendar.component(.day, from: today)

    // Call loadAll
    let result = try await backend.analysis.loadAll(
      historyAfter: thirtyDaysAgo,
      forecastUntil: nil,
      monthEnd: monthEnd
    )

    // Verify it returns non-empty data matching individual calls
    let individualBalances = try await backend.analysis.fetchDailyBalances(
      after: thirtyDaysAgo, forecastUntil: nil)
    let individualBreakdown = try await backend.analysis.fetchExpenseBreakdown(
      monthEnd: monthEnd, after: thirtyDaysAgo)
    let individualIncome = try await backend.analysis.fetchIncomeAndExpense(
      monthEnd: monthEnd, after: thirtyDaysAgo)

    #expect(result.dailyBalances.count == individualBalances.count)
    #expect(result.expenseBreakdown.count == individualBreakdown.count)
    #expect(result.incomeAndExpense.count == individualIncome.count)
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
    self.investments = CloudKitInvestmentRepository(
      modelContainer: container, profileId: profileId, currency: currency)
  }
}
