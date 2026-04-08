import Foundation
import Testing

@testable import Moolah

@Suite("Domain Models Tests")
struct DomainModelsTests {

  // MARK: - DailyBalance Tests

  @Test("DailyBalance computes availableFunds correctly")
  func dailyBalanceAvailableFunds() {
    let balance = DailyBalance(
      date: Date(),
      balance: MonetaryAmount(cents: 100000, currency: .defaultCurrency),
      earmarked: MonetaryAmount(cents: 30000, currency: .defaultCurrency),
      investments: MonetaryAmount(cents: 50000, currency: .defaultCurrency)
    )

    #expect(balance.availableFunds.cents == 70000)  // 100000 - 30000
  }

  @Test("DailyBalance computes netWorth with investments only")
  func dailyBalanceNetWorthInvestments() {
    let balance = DailyBalance(
      date: Date(),
      balance: MonetaryAmount(cents: 100000, currency: .defaultCurrency),
      earmarked: MonetaryAmount(cents: 0, currency: .defaultCurrency),
      investments: MonetaryAmount(cents: 50000, currency: .defaultCurrency),
      investmentValue: nil
    )

    #expect(balance.netWorth.cents == 150000)  // 100000 + 50000
  }

  @Test("DailyBalance computes netWorth with investmentValue")
  func dailyBalanceNetWorthInvestmentValue() {
    let balance = DailyBalance(
      date: Date(),
      balance: MonetaryAmount(cents: 100000, currency: .defaultCurrency),
      earmarked: MonetaryAmount(cents: 0, currency: .defaultCurrency),
      investments: MonetaryAmount(cents: 50000, currency: .defaultCurrency),
      investmentValue: MonetaryAmount(cents: 60000, currency: .defaultCurrency)
    )

    #expect(balance.netWorth.cents == 160000)  // 100000 + 60000 (uses investmentValue)
  }

  @Test("DailyBalance convenience initializer sets isForecast to false")
  func dailyBalanceConvenienceInitializer() {
    let balance = DailyBalance(
      date: Date(),
      balance: MonetaryAmount(cents: 100000, currency: .defaultCurrency)
    )

    #expect(balance.isForecast == false)
    #expect(balance.bestFit == nil)
  }

  @Test("DailyBalance id is ISO8601 date string")
  func dailyBalanceId() {
    let date = Date(timeIntervalSince1970: 1_672_531_200)  // 2023-01-01
    let balance = DailyBalance(
      date: date,
      balance: .zero
    )

    #expect(balance.id == date.ISO8601Format())
  }

  // MARK: - ExpenseBreakdown Tests

  @Test("ExpenseBreakdown id combines category and month")
  func expenseBreakdownId() {
    let categoryId = UUID()
    let breakdown = ExpenseBreakdown(
      categoryId: categoryId,
      month: "202604",
      totalExpenses: MonetaryAmount(cents: 50000, currency: .defaultCurrency)
    )

    #expect(breakdown.id == "\(categoryId.uuidString)-202604")
  }

  @Test("ExpenseBreakdown id handles uncategorized")
  func expenseBreakdownUncategorizedId() {
    let breakdown = ExpenseBreakdown(
      categoryId: nil,
      month: "202604",
      totalExpenses: MonetaryAmount(cents: 50000, currency: .defaultCurrency)
    )

    #expect(breakdown.id == "uncategorized-202604")
  }

  @Test("ExpenseBreakdown monthDate parses YYYYMM format")
  func expenseBreakdownMonthDate() {
    let breakdown = ExpenseBreakdown(
      categoryId: nil,
      month: "202604",
      totalExpenses: .zero
    )

    let monthDate = breakdown.monthDate
    #expect(monthDate != nil)

    let calendar = Calendar.current
    let components = calendar.dateComponents([.year, .month], from: monthDate!)
    #expect(components.year == 2026)
    #expect(components.month == 4)
  }

  // MARK: - MonthlyIncomeExpense Tests

  @Test("MonthlyIncomeExpense computes totalIncome")
  func monthlyIncomeExpenseTotalIncome() {
    let data = MonthlyIncomeExpense(
      month: "202604",
      start: Date(),
      end: Date(),
      income: MonetaryAmount(cents: 100000, currency: .defaultCurrency),
      expense: MonetaryAmount(cents: 50000, currency: .defaultCurrency),
      profit: MonetaryAmount(cents: 50000, currency: .defaultCurrency),
      earmarkedIncome: MonetaryAmount(cents: 20000, currency: .defaultCurrency),
      earmarkedExpense: MonetaryAmount(cents: 10000, currency: .defaultCurrency),
      earmarkedProfit: MonetaryAmount(cents: 10000, currency: .defaultCurrency)
    )

    #expect(data.totalIncome.cents == 120000)  // 100000 + 20000
  }

  @Test("MonthlyIncomeExpense computes totalExpense")
  func monthlyIncomeExpenseTotalExpense() {
    let data = MonthlyIncomeExpense(
      month: "202604",
      start: Date(),
      end: Date(),
      income: MonetaryAmount(cents: 100000, currency: .defaultCurrency),
      expense: MonetaryAmount(cents: 50000, currency: .defaultCurrency),
      profit: MonetaryAmount(cents: 50000, currency: .defaultCurrency),
      earmarkedIncome: MonetaryAmount(cents: 20000, currency: .defaultCurrency),
      earmarkedExpense: MonetaryAmount(cents: 10000, currency: .defaultCurrency),
      earmarkedProfit: MonetaryAmount(cents: 10000, currency: .defaultCurrency)
    )

    #expect(data.totalExpense.cents == 60000)  // 50000 + 10000
  }

  @Test("MonthlyIncomeExpense computes totalProfit")
  func monthlyIncomeExpenseTotalProfit() {
    let data = MonthlyIncomeExpense(
      month: "202604",
      start: Date(),
      end: Date(),
      income: MonetaryAmount(cents: 100000, currency: .defaultCurrency),
      expense: MonetaryAmount(cents: 50000, currency: .defaultCurrency),
      profit: MonetaryAmount(cents: 50000, currency: .defaultCurrency),
      earmarkedIncome: MonetaryAmount(cents: 20000, currency: .defaultCurrency),
      earmarkedExpense: MonetaryAmount(cents: 10000, currency: .defaultCurrency),
      earmarkedProfit: MonetaryAmount(cents: 10000, currency: .defaultCurrency)
    )

    #expect(data.totalProfit.cents == 60000)  // 50000 + 10000
  }
}
