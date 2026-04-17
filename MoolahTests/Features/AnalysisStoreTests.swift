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
    let (backend, _) = try TestBackend.create()
    let store = AnalysisStore(
      repository: backend.analysis, defaults: makeDefaults())
    #expect(store.historyMonths == 12)
    #expect(store.forecastMonths == 1)
  }

  @Test("persists historyMonths across instances")
  func historyMonthsPersists() throws {
    let defaults = makeDefaults()

    let (backend1, _) = try TestBackend.create()
    let store1 = AnalysisStore(
      repository: backend1.analysis, defaults: defaults)
    store1.historyMonths = 6

    let (backend2, _) = try TestBackend.create()
    let store2 = AnalysisStore(
      repository: backend2.analysis, defaults: defaults)
    #expect(store2.historyMonths == 6)
  }

  @Test("persists forecastMonths across instances")
  func forecastMonthsPersists() throws {
    let defaults = makeDefaults()

    let (backend1, _) = try TestBackend.create()
    let store1 = AnalysisStore(
      repository: backend1.analysis, defaults: defaults)
    store1.forecastMonths = 3

    let (backend2, _) = try TestBackend.create()
    let store2 = AnalysisStore(
      repository: backend2.analysis, defaults: defaults)
    #expect(store2.forecastMonths == 3)
  }

  @Test("forecastMonths=0 (None) persists correctly")
  func forecastMonthsZeroPersists() throws {
    let defaults = makeDefaults()

    let (backend1, _) = try TestBackend.create()
    let store1 = AnalysisStore(
      repository: backend1.analysis, defaults: defaults)
    store1.forecastMonths = 0

    let (backend2, _) = try TestBackend.create()
    let store2 = AnalysisStore(
      repository: backend2.analysis, defaults: defaults)
    #expect(store2.forecastMonths == 0)
  }
}

@Suite("AnalysisStore — categoriesOverTime")
@MainActor
struct AnalysisStoreCategoriesOverTimeTests {

  private func amt(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: .defaultTestInstrument)
  }

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
        totalExpenses: amt(Decimal(string: "-100.00")!))
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].categoryId == catId)
    #expect(result[0].points.count == 1)
    #expect(result[0].points[0].actualAmount == Decimal(string: "100.00")!)
    #expect(result[0].points[0].percentage == 100.0)
  }

  @Test func multipleCategoriesPercentageComputation() {
    let cat1 = UUID()
    let cat2 = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: cat1, month: "202604",
        totalExpenses: amt(Decimal(string: "-750.00")!)),
      ExpenseBreakdown(
        categoryId: cat2, month: "202604",
        totalExpenses: amt(Decimal(string: "-250.00")!)),
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
        totalExpenses: amt(Decimal(string: "-300.00")!)),
      ExpenseBreakdown(
        categoryId: childId, month: "202604",
        totalExpenses: amt(Decimal(string: "-200.00")!)),
    ]
    let categories = Categories(from: [
      Category(id: rootId, name: "Food"),
      Category(id: childId, name: "Groceries", parentId: rootId),
    ])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].categoryId == rootId)
    #expect(result[0].points[0].actualAmount == Decimal(string: "500.00")!)
  }

  @Test func multipleMonthsOrdered() {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202606",
        totalExpenses: amt(Decimal(string: "-100.00")!)),
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: amt(Decimal(string: "-200.00")!)),
      ExpenseBreakdown(
        categoryId: catId, month: "202605",
        totalExpenses: amt(Decimal(string: "-150.00")!)),
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
        totalExpenses: amt(Decimal(string: "-600.00")!)),
      ExpenseBreakdown(
        categoryId: nil, month: "202604",
        totalExpenses: amt(Decimal(string: "-400.00")!)),
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 2)
    let uncategorized = result.first { $0.categoryId == nil }
    #expect(uncategorized != nil)
    #expect(uncategorized?.points[0].actualAmount == Decimal(string: "400.00")!)
    #expect(uncategorized?.points[0].percentage == 40.0)
  }

  @Test func positiveExpenseValuesClampsToZero() {
    // If server somehow returns positive expenses, they negate to negative
    // and get clamped to 0 (matching web app's Math.max(0, ...) behavior)
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: amt(Decimal(string: "100.00")!))
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].points[0].actualAmount == 0)
    #expect(result[0].points[0].percentage == 0.0)
  }

  @Test func allZeroMonthsHandled() {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202604",
        totalExpenses: amt(0))
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    #expect(result.count == 1)
    #expect(result[0].points[0].actualAmount == 0)
    #expect(result[0].points[0].percentage == 0.0)
  }
}

// MARK: - AnalysisStore.buildExpenseBreakdown

@Suite("AnalysisStore — buildExpenseBreakdown")
@MainActor
struct AnalysisStoreBuildExpenseBreakdownTests {

  private func amt(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: .defaultTestInstrument)
  }

  @Test func emptyBreakdownReturnsNoEntries() {
    let result = AnalysisStore.buildExpenseBreakdown(
      from: [], categories: Categories(from: []), selectedCategoryId: nil)
    #expect(result.isEmpty)
  }

  @Test func topLevelRollsUpChildIntoRoot() {
    // Repro: user reports a root category total does not include descendants.
    let foodId = UUID()
    let groceriesId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: foodId, month: "202604",
        totalExpenses: amt(Decimal(string: "-100.00")!)),
      ExpenseBreakdown(
        categoryId: groceriesId, month: "202604",
        totalExpenses: amt(Decimal(string: "-300.00")!)),
    ]
    let categories = Categories(from: [
      Category(id: foodId, name: "Food"),
      Category(id: groceriesId, name: "Groceries", parentId: foodId),
    ])

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: nil)

    #expect(result.count == 1)
    #expect(result[0].categoryId == foodId)
    #expect(result[0].totalExpenses.quantity == Decimal(string: "400.00")!)
    #expect(result[0].percentage == 100.0)
  }

  @Test func topLevelRollsUpMultipleLevelsOfDescendants() {
    let foodId = UUID()
    let groceriesId = UUID()
    let organicId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: foodId, month: "202604",
        totalExpenses: amt(Decimal(string: "-10.00")!)),
      ExpenseBreakdown(
        categoryId: groceriesId, month: "202604",
        totalExpenses: amt(Decimal(string: "-20.00")!)),
      ExpenseBreakdown(
        categoryId: organicId, month: "202604",
        totalExpenses: amt(Decimal(string: "-30.00")!)),
    ]
    let categories = Categories(from: [
      Category(id: foodId, name: "Food"),
      Category(id: groceriesId, name: "Groceries", parentId: foodId),
      Category(id: organicId, name: "Organic", parentId: groceriesId),
    ])

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: nil)

    #expect(result.count == 1)
    #expect(result[0].categoryId == foodId)
    #expect(result[0].totalExpenses.quantity == Decimal(string: "60.00")!)
  }

  @Test func topLevelSortsByTotalDescending() {
    let foodId = UUID()
    let transportId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: foodId, month: "202604",
        totalExpenses: amt(Decimal(string: "-200.00")!)),
      ExpenseBreakdown(
        categoryId: transportId, month: "202604",
        totalExpenses: amt(Decimal(string: "-600.00")!)),
    ]
    let categories = Categories(from: [
      Category(id: foodId, name: "Food"),
      Category(id: transportId, name: "Transport"),
    ])

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: nil)

    #expect(result.count == 2)
    #expect(result[0].categoryId == transportId)
    #expect(result[0].percentage == 75.0)
    #expect(result[1].categoryId == foodId)
    #expect(result[1].percentage == 25.0)
  }

  @Test func topLevelIncludesUncategorized() {
    let foodId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: foodId, month: "202604",
        totalExpenses: amt(Decimal(string: "-300.00")!)),
      ExpenseBreakdown(
        categoryId: nil, month: "202604",
        totalExpenses: amt(Decimal(string: "-100.00")!)),
    ]
    let categories = Categories(from: [Category(id: foodId, name: "Food")])

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: nil)

    #expect(result.count == 2)
    let food = result.first { $0.categoryId == foodId }
    #expect(food?.totalExpenses.quantity == Decimal(string: "300.00")!)
    let uncategorized = result.first { $0.categoryId == nil }
    #expect(uncategorized?.totalExpenses.quantity == Decimal(string: "100.00")!)
  }

  @Test func drilledInShowsChildrenWithDescendantsRolledUp() {
    let foodId = UUID()
    let groceriesId = UUID()
    let organicId = UUID()
    let restaurantsId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: foodId, month: "202604",
        totalExpenses: amt(Decimal(string: "-10.00")!)),
      ExpenseBreakdown(
        categoryId: groceriesId, month: "202604",
        totalExpenses: amt(Decimal(string: "-20.00")!)),
      ExpenseBreakdown(
        categoryId: organicId, month: "202604",
        totalExpenses: amt(Decimal(string: "-30.00")!)),
      ExpenseBreakdown(
        categoryId: restaurantsId, month: "202604",
        totalExpenses: amt(Decimal(string: "-40.00")!)),
    ]
    let categories = Categories(from: [
      Category(id: foodId, name: "Food"),
      Category(id: groceriesId, name: "Groceries", parentId: foodId),
      Category(id: organicId, name: "Organic", parentId: groceriesId),
      Category(id: restaurantsId, name: "Restaurants", parentId: foodId),
    ])

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: foodId)

    // Groceries direct (20) + Organic (30) = 50; Restaurants = 40. Food-direct (10) excluded.
    #expect(result.count == 2)
    let groceries = result.first { $0.categoryId == groceriesId }
    #expect(groceries?.totalExpenses.quantity == Decimal(string: "50.00")!)
    let restaurants = result.first { $0.categoryId == restaurantsId }
    #expect(restaurants?.totalExpenses.quantity == Decimal(string: "40.00")!)
  }

  @Test func drilledInExcludesItemsOutsideSubtree() {
    let foodId = UUID()
    let groceriesId = UUID()
    let transportId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: groceriesId, month: "202604",
        totalExpenses: amt(Decimal(string: "-100.00")!)),
      ExpenseBreakdown(
        categoryId: transportId, month: "202604",
        totalExpenses: amt(Decimal(string: "-200.00")!)),
    ]
    let categories = Categories(from: [
      Category(id: foodId, name: "Food"),
      Category(id: groceriesId, name: "Groceries", parentId: foodId),
      Category(id: transportId, name: "Transport"),
    ])

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: foodId)

    #expect(result.count == 1)
    #expect(result[0].categoryId == groceriesId)
    #expect(result[0].totalExpenses.quantity == Decimal(string: "100.00")!)
    #expect(result[0].percentage == 100.0)
  }

  @Test func multipleMonthsAccumulateIntoSameRollupTarget() {
    let foodId = UUID()
    let groceriesId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: groceriesId, month: "202604",
        totalExpenses: amt(Decimal(string: "-100.00")!)),
      ExpenseBreakdown(
        categoryId: groceriesId, month: "202605",
        totalExpenses: amt(Decimal(string: "-200.00")!)),
      ExpenseBreakdown(
        categoryId: foodId, month: "202605",
        totalExpenses: amt(Decimal(string: "-50.00")!)),
    ]
    let categories = Categories(from: [
      Category(id: foodId, name: "Food"),
      Category(id: groceriesId, name: "Groceries", parentId: foodId),
    ])

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: nil)

    #expect(result.count == 1)
    #expect(result[0].categoryId == foodId)
    #expect(result[0].totalExpenses.quantity == Decimal(string: "350.00")!)
  }

  @Test func positiveExpensesClampToZero() {
    // Server returns negative for expenses; positive values are refunds.
    // Matching web app's Math.max(0, ...) behavior, net-positive rollups clamp to zero.
    let foodId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: foodId, month: "202604",
        totalExpenses: amt(Decimal(string: "100.00")!))
    ]
    let categories = Categories(from: [Category(id: foodId, name: "Food")])

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: nil)

    #expect(result.count == 1)
    #expect(result[0].totalExpenses.quantity == 0)
    #expect(result[0].percentage == 0)
  }
}

// MARK: - IncomeExpenseTableCard.cumulativeSavings

@Suite("IncomeExpenseTableCard — cumulativeSavings")
struct IncomeExpenseTableCardCumulativeSavingsTests {

  private let instrument: Instrument = .defaultTestInstrument

  private func amount(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: instrument)
  }

  private func monthData(
    month: String,
    income: Decimal,
    expense: Decimal,
    earmarkedIncome: Decimal = 0,
    earmarkedExpense: Decimal = 0
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
      monthData(
        month: "202604", income: Decimal(string: "5000.00")!, expense: Decimal(string: "3000.00")!),
      monthData(
        month: "202603", income: Decimal(string: "4000.00")!, expense: Decimal(string: "3500.00")!),
      monthData(
        month: "202602", income: Decimal(string: "4500.00")!, expense: Decimal(string: "2000.00")!),
    ]

    let result = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[0], in: data, includeEarmarks: false)

    #expect(result.quantity == Decimal(string: "2000.00")!)  // 5000 - 3000
  }

  @Test("second row accumulates first two rows")
  func secondRowAccumulatesTwo() {
    let data = [
      monthData(
        month: "202604", income: Decimal(string: "5000.00")!, expense: Decimal(string: "3000.00")!),
      monthData(
        month: "202603", income: Decimal(string: "4000.00")!, expense: Decimal(string: "3500.00")!),
      monthData(
        month: "202602", income: Decimal(string: "4500.00")!, expense: Decimal(string: "2000.00")!),
    ]

    let result = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[1], in: data, includeEarmarks: false)

    // (5000 - 3000) + (4000 - 3500) = 2000 + 500 = 2500
    #expect(result.quantity == Decimal(string: "2500.00")!)
  }

  @Test("last row is grand total of all savings")
  func lastRowIsGrandTotal() {
    let data = [
      monthData(
        month: "202604", income: Decimal(string: "5000.00")!, expense: Decimal(string: "3000.00")!),
      monthData(
        month: "202603", income: Decimal(string: "4000.00")!, expense: Decimal(string: "3500.00")!),
      monthData(
        month: "202602", income: Decimal(string: "4500.00")!, expense: Decimal(string: "2000.00")!),
    ]

    let result = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[2], in: data, includeEarmarks: false)

    // 2000 + 500 + 2500 = 5000
    #expect(result.quantity == Decimal(string: "5000.00")!)
  }

  @Test("includeEarmarks uses totalProfit instead of profit")
  func includeEarmarksUsesTotalProfit() {
    let data = [
      monthData(
        month: "202604", income: Decimal(string: "5000.00")!, expense: Decimal(string: "3000.00")!,
        earmarkedIncome: Decimal(string: "1000.00")!, earmarkedExpense: Decimal(string: "500.00")!),
      monthData(
        month: "202603", income: Decimal(string: "4000.00")!, expense: Decimal(string: "3500.00")!,
        earmarkedIncome: Decimal(string: "200.00")!, earmarkedExpense: Decimal(string: "100.00")!),
    ]

    let withoutEarmarks = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[1], in: data, includeEarmarks: false)
    let withEarmarks = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[1], in: data, includeEarmarks: true)

    // Without: (5000-3000) + (4000-3500) = 2500
    #expect(withoutEarmarks.quantity == Decimal(string: "2500.00")!)
    // With: (5000-3000+1000-500) + (4000-3500+200-100) = 2500 + 600 = 3100
    #expect(withEarmarks.quantity == Decimal(string: "3100.00")!)
  }

  @Test("single row total equals its own savings")
  func singleRow() {
    let data = [
      monthData(
        month: "202604", income: Decimal(string: "9000.00")!, expense: Decimal(string: "8000.00")!)
    ]

    let result = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[0], in: data, includeEarmarks: false)

    #expect(result.quantity == Decimal(string: "1000.00")!)
  }

  @Test("handles negative savings correctly")
  func negativeSavings() {
    let data = [
      monthData(
        month: "202604", income: Decimal(string: "2000.00")!, expense: Decimal(string: "5000.00")!),
      monthData(
        month: "202603", income: Decimal(string: "3000.00")!, expense: Decimal(string: "1000.00")!),
    ]

    let first = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[0], in: data, includeEarmarks: false)
    let second = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[1], in: data, includeEarmarks: false)

    #expect(first.quantity == Decimal(string: "-3000.00")!)  // 2000 - 5000
    #expect(second.quantity == Decimal(string: "-1000.00")!)  // -3000 + 2000
  }

  @Test("unknown item returns zero")
  func unknownItem() {
    let data = [
      monthData(
        month: "202604", income: Decimal(string: "5000.00")!, expense: Decimal(string: "3000.00")!)
    ]
    let unknown = monthData(
      month: "202501", income: Decimal(string: "1000.00")!, expense: Decimal(string: "500.00")!)

    let result = IncomeExpenseTableCard.cumulativeSavings(
      upTo: unknown, in: data, includeEarmarks: false)

    #expect(result.isZero)
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
    daysFromToday: Int, quantity: Decimal = Decimal(string: "10.00")!, isForecast: Bool = false,
    relativeTo today: Date = Date()
  ) -> DailyBalance {
    let amount = InstrumentAmount(quantity: quantity, instrument: .defaultTestInstrument)
    if isForecast {
      return DailyBalance(
        date: date(daysFromToday, relativeTo: today),
        balance: amount,
        earmarked: .zero(instrument: .defaultTestInstrument),
        availableFunds: amount,
        investments: .zero(instrument: .defaultTestInstrument),
        investmentValue: nil,
        netWorth: amount,
        bestFit: nil,
        isForecast: true
      )
    }
    return DailyBalance(
      date: date(daysFromToday, relativeTo: today),
      balance: amount,
      earmarked: .zero(instrument: .defaultTestInstrument),
      investments: .zero(instrument: .defaultTestInstrument),
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
    #expect(result[1].balance.quantity == result[0].balance.quantity)
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
      balance(daysFromToday: -3, quantity: Decimal(string: "10.00")!, relativeTo: today),
      balance(
        daysFromToday: 5, quantity: Decimal(string: "15.00")!, isForecast: true, relativeTo: today),
    ]

    let forecastUntil = date(30, relativeTo: today)
    let result = AnalysisStore.extrapolateBalances(
      balances, today: today, forecastUntil: forecastUntil)

    let forecasts = result.filter { $0.isForecast }
    // Forecast should be extended back to today using the last actual balance
    #expect(forecasts.count >= 2)
    #expect(calendar.startOfDay(for: forecasts[0].date) == today)
    #expect(forecasts[0].balance.quantity == Decimal(string: "10.00")!)  // Last actual balance value
  }

  @Test func extendsForecastToEndDate() {
    let today = calendar.startOfDay(for: Date())
    let forecastUntil = date(30, relativeTo: today)
    let balances = [
      balance(daysFromToday: -3, quantity: Decimal(string: "10.00")!, relativeTo: today),
      balance(
        daysFromToday: 5, quantity: Decimal(string: "15.00")!, isForecast: true, relativeTo: today),
    ]

    let result = AnalysisStore.extrapolateBalances(
      balances, today: today, forecastUntil: forecastUntil)

    let forecasts = result.filter { $0.isForecast }
    let lastForecast = forecasts.last!
    #expect(calendar.startOfDay(for: lastForecast.date) == forecastUntil)
    #expect(lastForecast.balance.quantity == Decimal(string: "15.00")!)
  }

  @Test func noForecastDataSkipsForecastExtension() {
    let today = calendar.startOfDay(for: Date())
    let forecastUntil = date(30, relativeTo: today)
    let balances = [
      balance(daysFromToday: -3, quantity: Decimal(string: "10.00")!, relativeTo: today)
    ]

    let result = AnalysisStore.extrapolateBalances(
      balances, today: today, forecastUntil: forecastUntil)

    let forecasts = result.filter { $0.isForecast }
    #expect(forecasts.isEmpty)
  }

  @Test func resultIsSortedByDate() {
    let today = calendar.startOfDay(for: Date())
    let forecastUntil = date(30, relativeTo: today)
    let balances = [
      balance(daysFromToday: -10, quantity: Decimal(string: "8.00")!, relativeTo: today),
      balance(daysFromToday: -3, quantity: Decimal(string: "10.00")!, relativeTo: today),
      balance(
        daysFromToday: 5, quantity: Decimal(string: "15.00")!, isForecast: true, relativeTo: today),
      balance(
        daysFromToday: 15, quantity: Decimal(string: "12.00")!, isForecast: true, relativeTo: today),
    ]

    let result = AnalysisStore.extrapolateBalances(
      balances, today: today, forecastUntil: forecastUntil)

    for i in 1..<result.count {
      #expect(result[i].date >= result[i - 1].date)
    }
  }
}
