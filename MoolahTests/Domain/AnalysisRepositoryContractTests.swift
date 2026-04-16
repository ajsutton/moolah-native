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
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    // Add transactions on different dates
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!

    _ = try await backend.transactions.create(
      Transaction(
        date: yesterday,
        payee: "Income",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 1, type: .income)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: twoDaysAgo,
        payee: "Earlier Income",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: Decimal(string: "0.50")!, type: .income)
        ]))

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
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(
      id: UUID(),
      name: "Savings",
      instrument: .defaultTestInstrument
    )
    _ = try await backend.earmarks.create(earmark)

    // Add income (not earmarked)
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Income",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 1000, type: .income)
        ]))

    // Add earmarked income
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Earmarked Income",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 300, type: .income,
            earmarkId: earmark.id)
        ]))

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
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    // Add a scheduled transaction (weekly)
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Weekly Income",
        recurPeriod: .week,
        recurEvery: 1,
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 1, type: .income)
        ]))

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
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(
      id: UUID(),
      name: "Holiday",
      instrument: .defaultTestInstrument
    )
    _ = try await backend.earmarks.create(earmark)

    let today = Calendar.current.startOfDay(for: Date())

    // Earmarked income: +500
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Earmarked Save",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 5, type: .income,
            earmarkId: earmark.id)
        ]))

    // Earmarked expense: -200
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Earmarked Spend",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -2, type: .expense,
            earmarkId: earmark.id)
        ]))

    // Non-earmarked income: +1000
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Regular Income",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .income)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    #expect(!balances.isEmpty)
    let todayBalance = balances.first { Calendar.current.isDate($0.date, inSameDayAs: today) }
    #expect(todayBalance != nil)

    // Total balance = 500 - 200 + 1000 = 1300 cents = 13.00
    #expect(todayBalance?.balance.quantity == 13)
    // Earmarked = 500 - 200 = 300 cents = 3.00
    #expect(todayBalance?.earmarked.quantity == 3)
    // Available = 1300 - 300 = 1000 cents = 10.00
    #expect(todayBalance?.availableFunds.quantity == 10)
  }

  @Test("daily balance + investments equals sum of current + investment account balances")
  func balanceInvariantCrossCheck() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let checking = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(checking)

    let savings = Account(
      id: UUID(),
      name: "Savings",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(savings)

    let investment = Account(
      id: UUID(),
      name: "Shares",
      type: .investment,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(investment)

    let today = Calendar.current.startOfDay(for: Date())

    // Income to checking
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Salary",
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: .defaultTestInstrument,
            quantity: 50, type: .income)
        ]))

    // Transfer checking -> investment
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Invest",
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: .defaultTestInstrument,
            quantity: -20, type: .transfer),
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: 20, type: .transfer),
        ]))

    // Income to savings
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Interest",
        legs: [
          TransactionLeg(
            accountId: savings.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .income)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    #expect(!balances.isEmpty)
    let todayBalance = balances.last!

    // balance = 5000 - 2000 + 1000 = 4000 cents = 40.00
    #expect(todayBalance.balance.quantity == 40)
    // investments = 2000 cents = 20.00
    #expect(todayBalance.investments.quantity == 20)
    // netWorth = 4000 + 2000 = 6000 cents = 60.00
    #expect(todayBalance.netWorth.quantity == 60)
  }

  // MARK: - Expense Breakdown Tests

  @Test("fetchExpenseBreakdown groups by category and month")
  func expenseBreakdownGrouping() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      instrument: .defaultTestInstrument
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
        date: thisMonth,
        payee: "Store A",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -1, type: .expense,
            categoryId: category.id)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: lastMonth,
        payee: "Store B",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: Decimal(string: "-0.50")!, type: .expense,
            categoryId: category.id)
        ]))

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
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    // Add a scheduled expense
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Monthly Bill",
        recurPeriod: .month,
        recurEvery: 1,
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -1, type: .expense)
        ]))

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
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let calendar = Calendar.current
    let onBoundary = calendar.date(from: DateComponents(year: 2025, month: 3, day: 25))!
    let afterBoundary = calendar.date(from: DateComponents(year: 2025, month: 3, day: 26))!

    _ = try await backend.transactions.create(
      Transaction(
        date: onBoundary,
        payee: "On boundary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -10, type: .expense,
            categoryId: category.id)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: afterBoundary,
        payee: "After boundary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -20, type: .expense,
            categoryId: category.id)
        ]))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    let marchEntries = breakdown.filter { $0.month == "202503" }
    let aprilEntries = breakdown.filter { $0.month == "202504" }

    #expect(marchEntries.count == 1, "Day 25 should belong to March financial month")
    #expect(aprilEntries.count == 1, "Day 26 should belong to April financial month")
    #expect(marchEntries[0].totalExpenses.quantity == -10)
    #expect(aprilEntries[0].totalExpenses.quantity == -20)
  }

  // MARK: - Income and Expense Tests

  @Test("fetchIncomeAndExpense groups by financial month using monthEnd")
  func incomeExpenseMonthBoundary() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let calendar = Calendar.current
    let onBoundary = calendar.date(from: DateComponents(year: 2025, month: 3, day: 25))!
    let afterBoundary = calendar.date(from: DateComponents(year: 2025, month: 3, day: 26))!

    _ = try await backend.transactions.create(
      Transaction(
        date: onBoundary,
        payee: "On boundary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .income)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: afterBoundary,
        payee: "After boundary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 20, type: .income)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    let march = data.first { $0.month == "202503" }
    let april = data.first { $0.month == "202504" }

    #expect(march != nil, "Should have March financial month")
    #expect(april != nil, "Should have April financial month")
    #expect(march?.income.quantity == 10)
    #expect(april?.income.quantity == 20)
  }

  @Test("fetchIncomeAndExpense computes profit correctly")
  func incomeExpenseProfitCalculation() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Income",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 5, type: .income)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Expense",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -2, type: .expense)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    // Verify profit calculation: profit = income + expense (expense is negative)
    for month in data {
      #expect(month.profit == month.income + month.expense)
    }
  }

  @Test("fetchIncomeAndExpense handles investment transfers as earmarked")
  func investmentTransfersAsEarmarked() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let currentAccount = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(
      currentAccount,
      openingBalance: InstrumentAmount(quantity: 10, instrument: .defaultTestInstrument)
    )

    let investmentAccount = Account(
      id: UUID(),
      name: "Investment",
      type: .investment,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(investmentAccount)

    // Transfer to investment (should count as earmarkedIncome)
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Investment Contribution",
        legs: [
          TransactionLeg(
            accountId: currentAccount.id, instrument: .defaultTestInstrument,
            quantity: -1, type: .transfer),
          TransactionLeg(
            accountId: investmentAccount.id, instrument: .defaultTestInstrument,
            quantity: 1, type: .transfer),
        ]))

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
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(bankAccount)

    let investmentA = Account(
      id: UUID(),
      name: "Shares",
      type: .investment,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(investmentA)

    let investmentB = Account(
      id: UUID(),
      name: "Bonds",
      type: .investment,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(investmentB)

    let today = Calendar.current.startOfDay(for: Date())

    // Bank -> Investment (should be earmarkedIncome)
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Invest",
        legs: [
          TransactionLeg(
            accountId: bankAccount.id, instrument: .defaultTestInstrument,
            quantity: -5, type: .transfer),
          TransactionLeg(
            accountId: investmentA.id, instrument: .defaultTestInstrument,
            quantity: 5, type: .transfer),
        ]))

    // Investment -> Bank (should be earmarkedExpense)
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Withdraw",
        legs: [
          TransactionLeg(
            accountId: investmentA.id, instrument: .defaultTestInstrument,
            quantity: -2, type: .transfer),
          TransactionLeg(
            accountId: bankAccount.id, instrument: .defaultTestInstrument,
            quantity: 2, type: .transfer),
        ]))

    // Investment -> Investment (should not affect income/expense)
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Rebalance",
        legs: [
          TransactionLeg(
            accountId: investmentA.id, instrument: .defaultTestInstrument,
            quantity: -1, type: .transfer),
          TransactionLeg(
            accountId: investmentB.id, instrument: .defaultTestInstrument,
            quantity: 1, type: .transfer),
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty, "Should have at least one month")
    let month = data[0]

    // Bank->Investment transfer: both legs counted in leg-based model
    #expect(month.earmarkedIncome.quantity == 6)

    // Investment->Bank transfer: both legs counted
    #expect(month.earmarkedExpense.quantity == 3)

    // Regular income/expense should be zero
    #expect(month.income.quantity == 0)
    #expect(month.expense.quantity == 0)
  }

  @Test("earmarked income without accountId excluded from balance, included in earmarked")
  func nullAccountIdEarmarkedHandling() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(
      id: UUID(),
      name: "Gift Fund",
      instrument: .defaultTestInstrument
    )
    _ = try await backend.earmarks.create(earmark)

    let today = Calendar.current.startOfDay(for: Date())

    // Regular income with accountId
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Salary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .income)
        ]))

    // Earmarked income with nil accountId (matches server's null-accountId earmark transactions)
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Gift",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .defaultTestInstrument,
            quantity: 5, type: .income,
            earmarkId: earmark.id)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // Income only includes legs with accountId (matching server's account_id IS NOT NULL check).
    // The earmarked income with nil accountId is excluded from main income.
    #expect(month.income.quantity == 10)
    // Earmarked income is tracked separately (regardless of accountId)
    #expect(month.earmarkedIncome.quantity == 5)
  }

  @Test("expense refunds (positive quantity) reduce expense total, not increase it")
  func expenseRefundsReduceTotal() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let today = Calendar.current.startOfDay(for: Date())

    // Normal expense: -100
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Purchase",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -100, type: .expense)
        ]))

    // Refund: +30 (positive quantity with type .expense reduces expense total)
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Refund",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 30, type: .expense)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // Net expense = -100 + 30 = -70 (refund reduces the total)
    // Using abs() would incorrectly give 100 + 30 = 130
    #expect(month.expense.quantity == -70)
    #expect(month.profit == month.income + month.expense)
  }

  // MARK: - Income/Expense Server Parity Tests
  //
  // These tests verify that the CloudKit analysis matches the server SQL semantics:
  //   income  = SUM(IF(type='income'  AND account_id IS NOT NULL, amount, 0))
  //   expense = SUM(IF(type='expense' AND account_id IS NOT NULL, amount, 0))
  // openingBalance is excluded from income/expense reports entirely.

  @Test("earmarked income/expense with accountId included in main totals")
  func earmarkedWithAccountIdInMainTotals() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(
      id: UUID(),
      name: "Holiday",
      instrument: .defaultTestInstrument
    )
    _ = try await backend.earmarks.create(earmark)

    let today = Calendar.current.startOfDay(for: Date())

    // Non-earmarked income: +100
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Salary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 100, type: .income)
        ]))

    // Earmarked income WITH accountId: +30 (in BOTH income and earmarkedIncome)
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Earmarked Income",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 30, type: .income,
            earmarkId: earmark.id)
        ]))

    // Non-earmarked expense: -50
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Groceries",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense)
        ]))

    // Earmarked expense WITH accountId: -20 (in BOTH expense and earmarkedExpense)
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Holiday Spend",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -20, type: .expense,
            earmarkId: earmark.id)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // Main totals include earmarked legs that have an accountId (matching server)
    #expect(month.income.quantity == 130)  // 100 + 30
    #expect(month.expense.quantity == -70)  // -50 + -20
    #expect(month.profit.quantity == 60)  // 130 + (-70)

    // Earmarked portion tracked separately
    #expect(month.earmarkedIncome.quantity == 30)
    #expect(month.earmarkedExpense.quantity == -20)
    #expect(month.earmarkedProfit.quantity == 10)
  }

  @Test("earmarked expense without accountId excluded from main expense total")
  func earmarkedExpenseNilAccountIdExcluded() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(
      id: UUID(),
      name: "Gift Fund",
      instrument: .defaultTestInstrument
    )
    _ = try await backend.earmarks.create(earmark)

    let today = Calendar.current.startOfDay(for: Date())

    // Regular expense with accountId: -80
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Shopping",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -80, type: .expense)
        ]))

    // Earmarked expense with nil accountId: -25
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Gift Expense",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .defaultTestInstrument,
            quantity: -25, type: .expense,
            earmarkId: earmark.id)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // Main expense excludes nil-accountId leg (matching server's account_id IS NOT NULL)
    #expect(month.expense.quantity == -80)
    // Earmarked expense still tracks it
    #expect(month.earmarkedExpense.quantity == -25)
  }

  @Test("openingBalance excluded from income/expense reports")
  func openingBalanceExcluded() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let today = Calendar.current.startOfDay(for: Date())

    // Opening balance: +500 (should NOT appear in income)
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Opening Balance",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 500, type: .openingBalance)
        ]))

    // Regular income: +100
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Salary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 100, type: .income)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // openingBalance is excluded from income (matching server which only counts type='income')
    #expect(month.income.quantity == 100)
    #expect(month.expense.quantity == 0)
    #expect(month.earmarkedIncome.quantity == 0)
  }

  @Test("mixed earmarked with and without accountId matches server semantics")
  func mixedEarmarkedAccountIdSemantics() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(
      id: UUID(),
      name: "Savings",
      instrument: .defaultTestInstrument
    )
    _ = try await backend.earmarks.create(earmark)

    let today = Calendar.current.startOfDay(for: Date())

    // Earmarked income WITH accountId: +200
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Earmarked Salary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 200, type: .income,
            earmarkId: earmark.id)
        ]))

    // Earmarked income WITHOUT accountId: +50
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Earmarked Gift",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .defaultTestInstrument,
            quantity: 50, type: .income,
            earmarkId: earmark.id)
        ]))

    // Earmarked expense WITH accountId: -80
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Earmarked Purchase",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -80, type: .expense,
            earmarkId: earmark.id)
        ]))

    // Earmarked expense WITHOUT accountId: -30
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Earmarked Deduction",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .defaultTestInstrument,
            quantity: -30, type: .expense,
            earmarkId: earmark.id)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // Main totals only include legs with accountId
    #expect(month.income.quantity == 200)  // only the +200 with accountId
    #expect(month.expense.quantity == -80)  // only the -80 with accountId

    // Earmarked totals include ALL earmarked legs regardless of accountId
    #expect(month.earmarkedIncome.quantity == 250)  // 200 + 50
    #expect(month.earmarkedExpense.quantity == -110)  // -80 + -30

    // Profit uses main totals
    #expect(month.profit.quantity == 120)  // 200 - 80
    #expect(month.earmarkedProfit.quantity == 140)  // 250 - 110
  }

  // MARK: - Category Balances Tests

  @Test("fetchCategoryBalances returns flat mapping")
  func categoryBalancesFlatMapping() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      instrument: .defaultTestInstrument
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
        date: today,
        payee: "Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense,
            categoryId: cat1.id)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Restaurant",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -30, type: .expense,
            categoryId: cat2.id)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Store 2",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -20, type: .expense,
            categoryId: cat1.id)
        ]))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange,
      transactionType: .expense,
      filters: nil
    )

    // Verify totals are correct
    #expect(
      balances[cat1.id] == InstrumentAmount(quantity: -70, instrument: .defaultTestInstrument))
    #expect(
      balances[cat2.id] == InstrumentAmount(quantity: -30, instrument: .defaultTestInstrument))
  }

  @Test("fetchCategoryBalances excludes scheduled transactions")
  func categoryBalancesExcludesScheduled() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      instrument: .defaultTestInstrument
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
        date: today,
        payee: "Landlord",
        recurPeriod: .month,
        recurEvery: 1,
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -1000, type: .expense,
            categoryId: cat.id)
        ]))

    // Completed transaction
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Landlord",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -1000, type: .expense,
            categoryId: cat.id)
        ]))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange,
      transactionType: .expense,
      filters: nil
    )

    // Only completed transaction counted
    #expect(
      balances[cat.id]
        == InstrumentAmount(quantity: -1000, instrument: .defaultTestInstrument))
  }

  @Test("fetchCategoryBalances filters by transaction type")
  func categoryBalancesFiltersByType() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let cat = Category(id: UUID(), name: "Salary")
    _ = try await backend.categories.create(cat)

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let dateRange = today...today

    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Employer",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 5000, type: .income,
            categoryId: cat.id)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense,
            categoryId: cat.id)
        ]))

    let incomeBalances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange,
      transactionType: .income,
      filters: nil
    )

    // Only income counted
    #expect(
      incomeBalances[cat.id]
        == InstrumentAmount(quantity: 5000, instrument: .defaultTestInstrument))

    let expenseBalances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange,
      transactionType: .expense,
      filters: nil
    )

    // Only expense counted
    #expect(
      expenseBalances[cat.id]
        == InstrumentAmount(quantity: -50, instrument: .defaultTestInstrument))
  }

  @Test("fetchCategoryBalances respects date range")
  func categoryBalancesRespectsDateRange() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      instrument: .defaultTestInstrument
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
        date: yesterday,
        payee: "Gas Station",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense,
            categoryId: cat.id)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: lastMonth,
        payee: "Gas Station",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -30, type: .expense,
            categoryId: cat.id)
        ]))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: yesterday...today,
      transactionType: .expense,
      filters: nil
    )

    // Only yesterday's transaction counted
    #expect(
      balances[cat.id]
        == InstrumentAmount(quantity: -50, instrument: .defaultTestInstrument))
  }

  @Test("fetchCategoryBalances applies additional filters")
  func categoryBalancesAppliesFilters() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account1 = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account1)

    let account2 = Account(
      id: UUID(),
      name: "Credit Card",
      type: .creditCard,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account2)

    let cat = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(cat)

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let dateRange = today...today

    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Store",
        legs: [
          TransactionLeg(
            accountId: account1.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense,
            categoryId: cat.id)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Store",
        legs: [
          TransactionLeg(
            accountId: account2.id, instrument: .defaultTestInstrument,
            quantity: -30, type: .expense,
            categoryId: cat.id)
        ]))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange,
      transactionType: .expense,
      filters: TransactionFilter(accountId: account1.id)
    )

    // Only account1 transaction counted
    #expect(
      balances[cat.id]
        == InstrumentAmount(quantity: -50, instrument: .defaultTestInstrument))
  }

  @Test("fetchCategoryBalances excludes transactions without category")
  func categoryBalancesRequiresCategory() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let cat = Category(id: UUID(), name: "Misc")
    _ = try await backend.categories.create(cat)

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let dateRange = today...today

    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense,
            categoryId: cat.id)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Uncategorized",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -30, type: .expense)
        ]))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange,
      transactionType: .expense,
      filters: nil
    )

    #expect(balances.count == 1)
    #expect(
      balances[cat.id]
        == InstrumentAmount(quantity: -50, instrument: .defaultTestInstrument))
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
      instrument: .defaultTestInstrument
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
          date: date,
          payee: "Store",
          legs: [
            TransactionLeg(
              accountId: account.id, instrument: .defaultTestInstrument,
              quantity: -1, type: .expense,
              categoryId: category.id)
          ]))
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

  // MARK: - Positive-Amount Transfer Tests

  @Test("daily balances handle positive-amount transfer from investment correctly")
  func positiveAmountTransferFromInvestment() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let checking = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(checking)

    let investment = Account(
      id: UUID(), name: "Trust Shares", type: .investment, instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(investment)

    let today = Calendar.current.startOfDay(for: Date())

    // Normal deposit: checking -> investment, negative amount on checking
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: .defaultTestInstrument,
            quantity: -10, type: .transfer),
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .transfer),
        ]))

    // Positive-amount transfer from investment (e.g. dividend reinvestment)
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        legs: [
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: 50, type: .transfer),
          TransactionLeg(
            accountId: checking.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .transfer),
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)
    let todayBalance = balances.last!

    // investments = -1000 (to_inv) + 5000 (from_inv positive) = net contribution of +1000 deposit + 5000 gain
    // Deposit: investments -= (-1000) = +1000
    // Positive from_inv: investments += 5000
    // Total investments = 6000 cents = 60.00
    #expect(todayBalance.investments.quantity == 60)

    // balance is the opposite: +(-1000) for deposit + -(5000) for from_inv
    // Deposit: balance += (-1000) = -1000
    // Positive from_inv: balance -= 5000 = -6000
    // Plus no other income, so balance = -6000 cents = -60.00
    #expect(todayBalance.balance.quantity == -60)
  }

  @Test("income/expense handles positive-amount transfer from investment correctly")
  func positiveAmountTransferIncomeExpense() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let checking = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(checking)

    let investment = Account(
      id: UUID(), name: "Trust Shares", type: .investment, instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(investment)

    let today = Calendar.current.startOfDay(for: Date())

    // Positive-amount transfer from investment (e.g. dividend reinvestment credited)
    // accountId=investment, amount=+5000 means investment gained value
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        legs: [
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: 50, type: .transfer),
          TransactionLeg(
            accountId: checking.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .transfer),
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)
    #expect(!data.isEmpty)
    let month = data[0]

    // Positive amount from investment: profit contribution = +5000
    // Positive -> earmarkedIncome (investment pool growth)
    #expect(month.earmarkedIncome.quantity == 50)
    #expect(month.earmarkedExpense.quantity == 0)
    #expect(month.earmarkedProfit.quantity == 50)
  }

  @Test("income/expense earmarkedProfit matches server formula for mixed transfers")
  func earmarkedProfitMatchesServer() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let checking = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(checking)

    let investment = Account(
      id: UUID(), name: "Shares", type: .investment, instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(investment)

    let today = Calendar.current.startOfDay(for: Date())

    // Deposit to investment: checking->investment, amount=-1000 cents = -10.00
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: .defaultTestInstrument,
            quantity: -10, type: .transfer),
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .transfer),
        ]))

    // Withdrawal from investment: investment->checking, amount=-500 cents = -5.00
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        legs: [
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: -5, type: .transfer),
          TransactionLeg(
            accountId: checking.id, instrument: .defaultTestInstrument,
            quantity: 5, type: .transfer),
        ]))

    // Positive-amount from investment (dividend reinvestment): investment->checking, amount=+3000 cents = +30.00
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        legs: [
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: 30, type: .transfer),
          TransactionLeg(
            accountId: checking.id, instrument: .defaultTestInstrument,
            quantity: -30, type: .transfer),
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)
    let month = data[0]

    // Server earmarkedProfit formula: sum(amount when from_inv) + sum(-amount when to_inv)
    // = (-500 + 3000) + -(-1000) = 2500 + 1000 = 3500 cents = 35.00
    #expect(month.earmarkedProfit.quantity == 35)

    // Breakdown:
    // Deposit (to_inv, -1000): profitContribution = +1000 -> earmarkedIncome
    // Withdrawal (from_inv, -500): profitContribution = -500 -> earmarkedExpense
    // Dividend (from_inv, +3000): profitContribution = +3000 -> earmarkedIncome
    #expect(month.earmarkedIncome.quantity == 40)  // 1000 + 3000 = 4000 cents = 40.00
    #expect(month.earmarkedExpense.quantity == 5)  // 500 cents = 5.00

    // earmarkedProfit is computed independently (not derived from earmarkedIncome/earmarkedExpense)
    // because transfer contributions use different sign conventions than expense transactions.
    #expect(month.earmarkedProfit.quantity == 35)
  }

  @Test("dailyBalances excludes nil-accountId legs from balance")
  func dailyBalancesNilAccountIdExcluded() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(
      id: UUID(),
      name: "Gift Fund",
      instrument: .defaultTestInstrument
    )
    _ = try await backend.earmarks.create(earmark)

    let today = Calendar.current.startOfDay(for: Date())

    // Regular income with accountId: +100
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Salary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 100, type: .income)
        ]))

    // Earmark-only income with nil accountId: +50
    // Should affect earmarked total but NOT balance (matching server's account_id IS NOT NULL)
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Gift",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .defaultTestInstrument,
            quantity: 50, type: .income,
            earmarkId: earmark.id)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    #expect(!balances.isEmpty)
    let todayBalance = balances.first { Calendar.current.isDate($0.date, inSameDayAs: today) }
    #expect(todayBalance != nil)

    // Balance should only include the leg with accountId (100), not the nil-accountId leg (50)
    #expect(todayBalance!.balance.quantity == 100)
    // Earmarked should include the nil-accountId leg
    #expect(todayBalance!.earmarked.quantity == 50)
    // Available funds = balance - earmarked
    #expect(todayBalance!.availableFunds.quantity == 50)
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
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(investmentAccount)

    let bankAccount = Account(
      id: UUID(),
      name: "Bank",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(bankAccount)

    // Create a transfer to the investment account
    let calendar = Calendar.current
    let day1 = calendar.date(from: DateComponents(year: 2025, month: 3, day: 1))!
    _ = try await backend.transactions.create(
      Transaction(
        date: day1,
        payee: "Invest",
        legs: [
          TransactionLeg(
            accountId: bankAccount.id, instrument: .defaultTestInstrument,
            quantity: -500, type: .transfer),
          TransactionLeg(
            accountId: investmentAccount.id, instrument: .defaultTestInstrument,
            quantity: 500, type: .transfer),
        ]))

    // Set investment value (market value is higher than contributed)
    let day2 = calendar.date(from: DateComponents(year: 2025, month: 3, day: 2))!
    try await backend.investments.setValue(
      accountId: investmentAccount.id,
      date: day2,
      value: InstrumentAmount(quantity: 550, instrument: .defaultTestInstrument)
    )

    // Create another transaction on day2 so we get a daily balance entry for it
    _ = try await backend.transactions.create(
      Transaction(
        date: day2,
        payee: "Interest",
        legs: [
          TransactionLeg(
            accountId: bankAccount.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .income)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    // Find the balance for day2
    let day2Start = calendar.startOfDay(for: day2)
    let day2Balance = balances.first { $0.date == day2Start }
    #expect(day2Balance != nil, "Should have a balance for day2")
    #expect(
      day2Balance?.investmentValue
        == InstrumentAmount(quantity: 550, instrument: .defaultTestInstrument),
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
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    // Create transactions on consecutive days with linearly increasing balances
    let calendar = Calendar.current
    let day1 = calendar.date(from: DateComponents(year: 2025, month: 3, day: 1))!
    let day2 = calendar.date(from: DateComponents(year: 2025, month: 3, day: 2))!
    let day3 = calendar.date(from: DateComponents(year: 2025, month: 3, day: 3))!

    // Day 1: +1000 cents = 10.00
    _ = try await backend.transactions.create(
      Transaction(
        date: day1,
        payee: "Day 1",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .income)
        ]))
    // Day 2: +1000 cents = 10.00 (cumulative 20.00)
    _ = try await backend.transactions.create(
      Transaction(
        date: day2,
        payee: "Day 2",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .income)
        ]))
    // Day 3: +1000 cents = 10.00 (cumulative 30.00)
    _ = try await backend.transactions.create(
      Transaction(
        date: day3,
        payee: "Day 3",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .income)
        ]))

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

    // bestFit for day1 should be close to 10.00 and day3 close to 30.00
    // Allow small floating point tolerance (within 0.01)
    #expect(abs(day1Balance!.bestFit!.quantity - 10) <= Decimal(string: "0.01")!)
    #expect(abs(day3Balance!.bestFit!.quantity - 30) <= Decimal(string: "0.01")!)
  }

  @Test("fetchDailyBalances returns nil bestFit with fewer than 2 data points")
  func dailyBalancesBestFitSinglePoint() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Single",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .income)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)
    #expect(balances.count == 1)
    #expect(balances[0].bestFit == nil, "bestFit should be nil with only 1 data point")
  }

  // MARK: - Expense Breakdown Uncategorized Tests

  @Test("fetchExpenseBreakdown excludes uncategorized expenses")
  func expenseBreakdownExcludesUncategorized() async throws {
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let cat = Category(id: UUID(), name: "Food")
    _ = try await backend.categories.create(cat)

    // Categorized expense
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Grocery Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -10, type: .expense,
            categoryId: cat.id)
        ]))

    // Uncategorized expense (no categoryId) — excluded by server: category_id IS NOT NULL
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Uncategorized Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -5, type: .expense)
        ]))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    // Only the categorized expense should appear
    #expect(breakdown.count == 1)
    #expect(breakdown[0].categoryId == cat.id)
    #expect(breakdown[0].totalExpenses.quantity == -10)
  }

  // MARK: - loadAll Tests

  // MARK: - Multi-Currency Conversion Tests

  @Test("expense breakdown converts foreign-currency legs to profile currency")
  func expenseBreakdownConvertsForeignCurrency() async throws {
    // USD -> AUD at 1.5x rate
    let conversion = FixedConversionService(rates: ["USD": Decimal(string: "1.5")!])
    let backend = CloudKitAnalysisTestBackend(conversionService: conversion)
    let account = Account(
      id: UUID(), name: "USD Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let today = Calendar.current.startOfDay(for: Date())
    let usd = Instrument.fiat(code: "USD")

    // USD expense: -100 USD should become -150 AUD
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "US Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: -100, type: .expense,
            categoryId: category.id)
        ]))

    // AUD expense: -50 AUD stays as-is
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "AU Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense,
            categoryId: category.id)
        ]))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    #expect(breakdown.count == 1)
    // -100 USD * 1.5 = -150 AUD, plus -50 AUD = -200 AUD
    #expect(breakdown[0].totalExpenses.quantity == -200)
    #expect(breakdown[0].totalExpenses.instrument == .defaultTestInstrument)
  }

  @Test("income/expense converts foreign-currency legs to profile currency")
  func incomeExpenseConvertsForeignCurrency() async throws {
    let conversion = FixedConversionService(rates: ["USD": Decimal(string: "1.5")!])
    let backend = CloudKitAnalysisTestBackend(conversionService: conversion)
    let account = Account(
      id: UUID(), name: "Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let today = Calendar.current.startOfDay(for: Date())
    let usd = Instrument.fiat(code: "USD")

    // USD income: +200 USD should become +300 AUD
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "US Employer",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: 200, type: .income)
        ]))

    // USD expense: -80 USD should become -120 AUD
    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "US Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: -80, type: .expense)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]
    #expect(month.income.quantity == 300)  // 200 USD * 1.5
    #expect(month.expense.quantity == -120)  // -80 USD * 1.5
    #expect(month.profit.quantity == 180)  // 300 + (-120)
    #expect(month.income.instrument == .defaultTestInstrument)
  }

  @Test("category balances converts foreign-currency legs to profile currency")
  func categoryBalancesConvertsForeignCurrency() async throws {
    let conversion = FixedConversionService(rates: ["USD": Decimal(string: "1.5")!])
    let backend = CloudKitAnalysisTestBackend(conversionService: conversion)
    let account = Account(
      id: UUID(), name: "Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Food")
    _ = try await backend.categories.create(category)

    let today = Calendar.current.startOfDay(for: Date())
    let usd = Instrument.fiat(code: "USD")

    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "US Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: -40, type: .expense,
            categoryId: category.id)
        ]))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: today...today,
      transactionType: .expense,
      filters: nil
    )

    // -40 USD * 1.5 = -60 AUD
    #expect(
      balances[category.id] == InstrumentAmount(quantity: -60, instrument: .defaultTestInstrument))
  }

  @Test("forecast converts foreign-currency scheduled transactions to profile currency")
  func forecastConvertsForeignCurrencyScheduled() async throws {
    // USD -> AUD at 1.5x rate. FixedConversionService ignores the conversion date,
    // so "current rate" is irrelevant to test outcome — the test just verifies we
    // don't crash and that the converted amount lands in the forecast balance.
    let conversion = FixedConversionService(rates: ["USD": Decimal(string: "1.5")!])
    let backend = CloudKitAnalysisTestBackend(conversionService: conversion)

    let audAccount = Account(
      id: UUID(), name: "AUD Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(audAccount)

    let calendar = Calendar(identifier: .gregorian)
    let today = calendar.startOfDay(for: Date())
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
    let nextWeek = calendar.date(byAdding: .day, value: 7, to: today)!
    let usd = Instrument.fiat(code: "USD")

    // Opening AUD balance so forecast has a starting value.
    _ = try await backend.transactions.create(
      Transaction(
        date: yesterday,
        payee: "Opening",
        legs: [
          TransactionLeg(
            accountId: audAccount.id, instrument: .defaultTestInstrument,
            quantity: 1000, type: .openingBalance)
        ]))

    // Scheduled USD expense -100 USD (one-off, future-dated).
    // Expected: pre-converted to -150 AUD before entering the forecast accumulator.
    _ = try await backend.transactions.create(
      Transaction(
        id: UUID(),
        date: tomorrow,
        payee: "US Subscription",
        recurPeriod: .once,
        legs: [
          TransactionLeg(
            accountId: audAccount.id, instrument: usd,
            quantity: -100, type: .expense)
        ]))

    // Fetch balances with forecast enabled.
    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil, forecastUntil: nextWeek)

    // There must be a forecast entry for tomorrow.
    let forecastEntry = balances.first { $0.date == tomorrow && $0.isForecast }
    #expect(forecastEntry != nil, "expected a forecast entry for tomorrow")

    // Starting balance was 1000 AUD; forecast leg is -100 USD * 1.5 = -150 AUD.
    // Running balance after the scheduled expense = 850 AUD.
    #expect(forecastEntry?.balance.quantity == 850)
    #expect(forecastEntry?.balance.instrument == .defaultTestInstrument)
  }

  @Test("forecast leaves profile-currency scheduled transactions unchanged")
  func forecastLeavesProfileCurrencyUnchanged() async throws {
    // Rate dict intentionally empty — if the code path tried to convert AUD legs
    // it would take the 1:1 fallback, but the intent is that same-currency legs
    // skip the conversion call entirely.
    let conversion = FixedConversionService(rates: [:])
    let backend = CloudKitAnalysisTestBackend(conversionService: conversion)

    let account = Account(
      id: UUID(), name: "AUD Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let calendar = Calendar(identifier: .gregorian)
    let today = calendar.startOfDay(for: Date())
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
    let nextWeek = calendar.date(byAdding: .day, value: 7, to: today)!

    _ = try await backend.transactions.create(
      Transaction(
        date: yesterday,
        payee: "Opening",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 500, type: .openingBalance)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        id: UUID(),
        date: tomorrow,
        payee: "Rent",
        recurPeriod: .once,
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -200, type: .expense)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil, forecastUntil: nextWeek)

    let forecastEntry = balances.first { $0.date == tomorrow && $0.isForecast }
    #expect(forecastEntry != nil)
    #expect(forecastEntry?.balance.quantity == 300)
  }

  @Test("single-currency profiles work without conversion")
  func singleCurrencyNoConversion() async throws {
    // Default backend has no conversion rates configured — single currency should work fine
    let backend = CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Food")
    _ = try await backend.categories.create(category)

    let today = Calendar.current.startOfDay(for: Date())

    _ = try await backend.transactions.create(
      Transaction(
        date: today,
        payee: "Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -25, type: .expense,
            categoryId: category.id)
        ]))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)
    #expect(breakdown.count == 1)
    #expect(breakdown[0].totalExpenses.quantity == -25)

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)
    #expect(!data.isEmpty)
    #expect(data[0].expense.quantity == -25)
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
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: today)!

    _ = try await backend.transactions.create(
      Transaction(
        date: calendar.date(byAdding: .day, value: -10, to: today)!,
        payee: "Salary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 500, type: .income)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: calendar.date(byAdding: .day, value: -5, to: today)!,
        payee: "Groceries",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -200, type: .expense)
        ]))

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
  let conversionService: any InstrumentConversionService

  init(conversionService customConversion: (any InstrumentConversionService)? = nil) {
    let container = try! TestModelContainer.create()
    let currency = Instrument.defaultTestInstrument
    self.auth = InMemoryAuthProvider()
    self.accounts = CloudKitAccountRepository(
      modelContainer: container)
    self.transactions = CloudKitTransactionRepository(
      modelContainer: container, instrument: currency)
    self.categories = CloudKitCategoryRepository(
      modelContainer: container)
    self.earmarks = CloudKitEarmarkRepository(
      modelContainer: container, instrument: currency)
    let conversion: any InstrumentConversionService
    if let customConversion {
      conversion = customConversion
    } else {
      let rateClient = FixedRateClient()
      let cacheDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-rates-\(UUID().uuidString)")
      let exchangeRates = ExchangeRateService(client: rateClient, cacheDirectory: cacheDir)
      conversion = FiatConversionService(exchangeRates: exchangeRates)
    }
    self.conversionService = conversion
    self.analysis = CloudKitAnalysisRepository(
      modelContainer: container, instrument: currency, conversionService: conversion)
    self.investments = CloudKitInvestmentRepository(
      modelContainer: container, instrument: currency)
  }
}
