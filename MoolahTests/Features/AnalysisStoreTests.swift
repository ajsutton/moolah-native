import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("AnalysisStore — filter persistence")
@MainActor
struct AnalysisStoreFilterPersistenceTests {

  private func makeDefaults() -> UserDefaults {
    let suiteName = "com.moolah.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  @Test("defaults to historyMonths=12 and forecastMonths=1 with no saved values")
  func defaultValues() throws {
    let (backend, _, _) = try TestBackend.create()
    let store = AnalysisStore(
      repository: backend.analysis, defaults: makeDefaults())
    #expect(store.historyMonths == 12)
    #expect(store.forecastMonths == 1)
  }

  @Test("persists historyMonths across instances")
  func historyMonthsPersists() throws {
    let defaults = makeDefaults()

    let (backend1, _, _) = try TestBackend.create()
    let store1 = AnalysisStore(
      repository: backend1.analysis, defaults: defaults)
    store1.historyMonths = 6

    let (backend2, _, _) = try TestBackend.create()
    let store2 = AnalysisStore(
      repository: backend2.analysis, defaults: defaults)
    #expect(store2.historyMonths == 6)
  }

  @Test("persists forecastMonths across instances")
  func forecastMonthsPersists() throws {
    let defaults = makeDefaults()

    let (backend1, _, _) = try TestBackend.create()
    let store1 = AnalysisStore(
      repository: backend1.analysis, defaults: defaults)
    store1.forecastMonths = 3

    let (backend2, _, _) = try TestBackend.create()
    let store2 = AnalysisStore(
      repository: backend2.analysis, defaults: defaults)
    #expect(store2.forecastMonths == 3)
  }

  @Test("forecastMonths=0 (None) persists correctly")
  func forecastMonthsZeroPersists() throws {
    let defaults = makeDefaults()

    let (backend1, _, _) = try TestBackend.create()
    let store1 = AnalysisStore(
      repository: backend1.analysis, defaults: defaults)
    store1.forecastMonths = 0

    let (backend2, _, _) = try TestBackend.create()
    let store2 = AnalysisStore(
      repository: backend2.analysis, defaults: defaults)
    #expect(store2.forecastMonths == 0)
  }
}

@Suite("AnalysisStore — categoriesOverTime")
@MainActor
struct AnalysisStoreCategoriesOverTimeTests {

  @Test func emptyBreakdownReturnsNoEntries() {
    let result = AnalysisStore.buildCategoriesOverTime(
      from: [], categories: Categories(from: []))
    #expect(result.isEmpty)
  }

  @Test func singleCategorySingleMonth() {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: MonetaryAmount(cents: -10000, currency: .defaultTestCurrency))
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].categoryId == catId)
    #expect(result[0].points.count == 1)
    #expect(result[0].points[0].actualCents == 10000)
    #expect(result[0].points[0].percentage == 100.0)
  }

  @Test func multipleCategoriesPercentageComputation() {
    let cat1 = UUID()
    let cat2 = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: cat1, month: "202604",
        totalExpenses: MonetaryAmount(cents: -75000, currency: .defaultTestCurrency)),
      ExpenseBreakdown(
        categoryId: cat2, month: "202604",
        totalExpenses: MonetaryAmount(cents: -25000, currency: .defaultTestCurrency)),
    ]
    let categories = Categories(from: [
      Category(id: cat1, name: "Groceries"),
      Category(id: cat2, name: "Transport"),
    ])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 2)
    #expect(result[0].categoryId == cat1)
    #expect(result[0].points[0].percentage == 75.0)
    #expect(result[1].categoryId == cat2)
    #expect(result[1].points[0].percentage == 25.0)
  }

  @Test func subcategoriesRollUpToRootLevel() {
    let rootId = UUID()
    let childId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: rootId, month: "202604",
        totalExpenses: MonetaryAmount(cents: -30000, currency: .defaultTestCurrency)),
      ExpenseBreakdown(
        categoryId: childId, month: "202604",
        totalExpenses: MonetaryAmount(cents: -20000, currency: .defaultTestCurrency)),
    ]
    let categories = Categories(from: [
      Category(id: rootId, name: "Food"),
      Category(id: childId, name: "Groceries", parentId: rootId),
    ])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].categoryId == rootId)
    #expect(result[0].points[0].actualCents == 50000)
  }

  @Test func multipleMonthsOrdered() {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202606",
        totalExpenses: MonetaryAmount(cents: -10000, currency: .defaultTestCurrency)),
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: MonetaryAmount(cents: -20000, currency: .defaultTestCurrency)),
      ExpenseBreakdown(
        categoryId: catId, month: "202605",
        totalExpenses: MonetaryAmount(cents: -15000, currency: .defaultTestCurrency)),
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].points.count == 3)
    #expect(result[0].points[0].month == "202604")
    #expect(result[0].points[1].month == "202605")
    #expect(result[0].points[2].month == "202606")
  }

  @Test func uncategorizedExpensesHandled() {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: MonetaryAmount(cents: -60000, currency: .defaultTestCurrency)),
      ExpenseBreakdown(
        categoryId: nil, month: "202604",
        totalExpenses: MonetaryAmount(cents: -40000, currency: .defaultTestCurrency)),
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 2)
    let uncategorized = result.first { $0.categoryId == nil }
    #expect(uncategorized != nil)
    #expect(uncategorized?.points[0].actualCents == 40000)
    #expect(uncategorized?.points[0].percentage == 40.0)
  }

  @Test func positiveExpenseValuesClampsToZero() {
    // If server somehow returns positive expenses, they negate to negative
    // and get clamped to 0 (matching web app's Math.max(0, ...) behavior)
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: MonetaryAmount(cents: 10000, currency: .defaultTestCurrency))
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].points[0].actualCents == 0)
    #expect(result[0].points[0].percentage == 0.0)
  }

  @Test func allZeroMonthsHandled() {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: MonetaryAmount(cents: 0, currency: .defaultTestCurrency))
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].points[0].actualCents == 0)
    #expect(result[0].points[0].percentage == 0.0)
  }
}

// MARK: - IncomeExpenseTableCard.cumulativeSavings

@Suite("IncomeExpenseTableCard — cumulativeSavings")
struct IncomeExpenseTableCardCumulativeSavingsTests {

  private let currency: Currency = .defaultTestCurrency

  private func amount(_ cents: Int) -> MonetaryAmount {
    MonetaryAmount(cents: cents, currency: currency)
  }

  private func monthData(
    month: String,
    income: Int,
    expense: Int,
    earmarkedIncome: Int = 0,
    earmarkedExpense: Int = 0
  ) -> MonthlyIncomeExpense {
    MonthlyIncomeExpense(
      month: month,
      start: Date(),
      end: Date(),
      income: amount(income),
      expense: amount(expense),
      profit: amount(income - expense),
      earmarkedIncome: amount(earmarkedIncome),
      earmarkedExpense: amount(earmarkedExpense),
      earmarkedProfit: amount(earmarkedIncome - earmarkedExpense)
    )
  }

  @Test("first row total savings equals its own savings")
  func firstRowEqualsOwnSavings() {
    let data = [
      monthData(month: "202604", income: 5000_00, expense: 3000_00),
      monthData(month: "202603", income: 4000_00, expense: 3500_00),
      monthData(month: "202602", income: 4500_00, expense: 2000_00),
    ]

    let result = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[0], in: data, includeEarmarks: false)

    #expect(result.cents == 2000_00)  // 5000 - 3000
  }

  @Test("second row accumulates first two rows")
  func secondRowAccumulatesTwo() {
    let data = [
      monthData(month: "202604", income: 5000_00, expense: 3000_00),
      monthData(month: "202603", income: 4000_00, expense: 3500_00),
      monthData(month: "202602", income: 4500_00, expense: 2000_00),
    ]

    let result = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[1], in: data, includeEarmarks: false)

    // (5000 - 3000) + (4000 - 3500) = 2000 + 500 = 2500
    #expect(result.cents == 2500_00)
  }

  @Test("last row is grand total of all savings")
  func lastRowIsGrandTotal() {
    let data = [
      monthData(month: "202604", income: 5000_00, expense: 3000_00),
      monthData(month: "202603", income: 4000_00, expense: 3500_00),
      monthData(month: "202602", income: 4500_00, expense: 2000_00),
    ]

    let result = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[2], in: data, includeEarmarks: false)

    // 2000 + 500 + 2500 = 5000
    #expect(result.cents == 5000_00)
  }

  @Test("includeEarmarks uses totalProfit instead of profit")
  func includeEarmarksUsesTotalProfit() {
    let data = [
      monthData(
        month: "202604", income: 5000_00, expense: 3000_00,
        earmarkedIncome: 1000_00, earmarkedExpense: 500_00),
      monthData(
        month: "202603", income: 4000_00, expense: 3500_00,
        earmarkedIncome: 200_00, earmarkedExpense: 100_00),
    ]

    let withoutEarmarks = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[1], in: data, includeEarmarks: false)
    let withEarmarks = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[1], in: data, includeEarmarks: true)

    // Without: (5000-3000) + (4000-3500) = 2500
    #expect(withoutEarmarks.cents == 2500_00)
    // With: (5000-3000+1000-500) + (4000-3500+200-100) = 2500 + 600 = 3100
    #expect(withEarmarks.cents == 3100_00)
  }

  @Test("single row total equals its own savings")
  func singleRow() {
    let data = [monthData(month: "202604", income: 9000_00, expense: 8000_00)]

    let result = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[0], in: data, includeEarmarks: false)

    #expect(result.cents == 1000_00)
  }

  @Test("handles negative savings correctly")
  func negativeSavings() {
    let data = [
      monthData(month: "202604", income: 2000_00, expense: 5000_00),
      monthData(month: "202603", income: 3000_00, expense: 1000_00),
    ]

    let first = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[0], in: data, includeEarmarks: false)
    let second = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[1], in: data, includeEarmarks: false)

    #expect(first.cents == -3000_00)  // 2000 - 5000
    #expect(second.cents == -1000_00)  // -3000 + 2000
  }

  @Test("unknown item returns zero")
  func unknownItem() {
    let data = [monthData(month: "202604", income: 5000_00, expense: 3000_00)]
    let unknown = monthData(month: "202501", income: 1000_00, expense: 500_00)

    let result = IncomeExpenseTableCard.cumulativeSavings(
      upTo: unknown, in: data, includeEarmarks: false)

    #expect(result.cents == 0)
  }
}

// MARK: - extrapolateBalances

@Suite("AnalysisStore — extrapolateBalances")
struct AnalysisStoreExtrapolateTests {

  private let calendar = Calendar.current

  private func date(_ daysFromToday: Int, relativeTo today: Date = Date()) -> Date {
    calendar.startOfDay(for: calendar.date(byAdding: .day, value: daysFromToday, to: today)!)
  }

  private func balance(
    daysFromToday: Int, cents: Int = 1000, isForecast: Bool = false,
    relativeTo today: Date = Date()
  ) -> DailyBalance {
    let amount = MonetaryAmount(cents: cents, currency: .defaultTestCurrency)
    if isForecast {
      return DailyBalance(
        date: date(daysFromToday, relativeTo: today),
        balance: amount,
        earmarked: .zero(currency: .defaultTestCurrency),
        availableFunds: amount,
        investments: .zero(currency: .defaultTestCurrency),
        investmentValue: nil,
        netWorth: amount,
        bestFit: nil,
        isForecast: true
      )
    }
    return DailyBalance(
      date: date(daysFromToday, relativeTo: today),
      balance: amount,
      earmarked: .zero(currency: .defaultTestCurrency),
      investments: .zero(currency: .defaultTestCurrency),
      investmentValue: nil
    )
  }

  @Test func emptyBalancesReturnsEmpty() {
    let result = AnalysisStore.extrapolateBalances([], today: Date(), forecastUntil: nil)
    #expect(result.isEmpty)
  }

  @Test func extendsActualBalancesToToday() {
    let today = calendar.startOfDay(for: Date())
    let balances = [balance(daysFromToday: -5, relativeTo: today)]

    let result = AnalysisStore.extrapolateBalances(balances, today: today, forecastUntil: nil)

    #expect(result.count == 2)
    #expect(calendar.startOfDay(for: result[0].date) == date(-5, relativeTo: today))
    #expect(calendar.startOfDay(for: result[1].date) == today)
    #expect(result[1].balance.cents == result[0].balance.cents)
    #expect(!result[1].isForecast)
  }

  @Test func doesNotExtendIfActualAlreadyAtToday() {
    let today = calendar.startOfDay(for: Date())
    let balances = [balance(daysFromToday: 0, relativeTo: today)]

    let result = AnalysisStore.extrapolateBalances(balances, today: today, forecastUntil: nil)

    #expect(result.count == 1)
  }

  @Test func extendsForecastBackToToday() {
    let today = calendar.startOfDay(for: Date())
    let balances = [
      balance(daysFromToday: -3, cents: 1000, relativeTo: today),
      balance(daysFromToday: 5, cents: 1500, isForecast: true, relativeTo: today),
    ]

    let forecastUntil = date(30, relativeTo: today)
    let result = AnalysisStore.extrapolateBalances(
      balances, today: today, forecastUntil: forecastUntil)

    let forecasts = result.filter { $0.isForecast }
    // Forecast should be extended back to today using the last actual balance
    #expect(forecasts.count >= 2)
    #expect(calendar.startOfDay(for: forecasts[0].date) == today)
    #expect(forecasts[0].balance.cents == 1000)  // Last actual balance value
  }

  @Test func extendsForecastToEndDate() {
    let today = calendar.startOfDay(for: Date())
    let forecastUntil = date(30, relativeTo: today)
    let balances = [
      balance(daysFromToday: -3, cents: 1000, relativeTo: today),
      balance(daysFromToday: 5, cents: 1500, isForecast: true, relativeTo: today),
    ]

    let result = AnalysisStore.extrapolateBalances(
      balances, today: today, forecastUntil: forecastUntil)

    let forecasts = result.filter { $0.isForecast }
    let lastForecast = forecasts.last!
    #expect(calendar.startOfDay(for: lastForecast.date) == forecastUntil)
    #expect(lastForecast.balance.cents == 1500)
  }

  @Test func noForecastDataSkipsForecastExtension() {
    let today = calendar.startOfDay(for: Date())
    let forecastUntil = date(30, relativeTo: today)
    let balances = [balance(daysFromToday: -3, cents: 1000, relativeTo: today)]

    let result = AnalysisStore.extrapolateBalances(
      balances, today: today, forecastUntil: forecastUntil)

    let forecasts = result.filter { $0.isForecast }
    #expect(forecasts.isEmpty)
  }

  @Test func resultIsSortedByDate() {
    let today = calendar.startOfDay(for: Date())
    let forecastUntil = date(30, relativeTo: today)
    let balances = [
      balance(daysFromToday: -10, cents: 800, relativeTo: today),
      balance(daysFromToday: -3, cents: 1000, relativeTo: today),
      balance(daysFromToday: 5, cents: 1500, isForecast: true, relativeTo: today),
      balance(daysFromToday: 15, cents: 1200, isForecast: true, relativeTo: today),
    ]

    let result = AnalysisStore.extrapolateBalances(
      balances, today: today, forecastUntil: forecastUntil)

    for i in 1..<result.count {
      #expect(result[i].date >= result[i - 1].date)
    }
  }
}
