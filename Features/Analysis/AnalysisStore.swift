import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class AnalysisStore {
  // State
  private(set) var dailyBalances: [DailyBalance] = []
  private(set) var expenseBreakdown: [ExpenseBreakdown] = []
  private(set) var incomeAndExpense: [MonthlyIncomeExpense] = []
  private(set) var isLoading = false
  private(set) var error: Error?

  // Filters (persisted across launches)
  var historyMonths: Int {
    didSet { defaults.set(historyMonths, forKey: "analysisHistoryMonths") }
  }
  var forecastMonths: Int {
    didSet { defaults.set(forecastMonths, forKey: "analysisForecastMonths") }
  }
  var showActualValues: Bool = false  // false = percentage, true = actual amounts

  let repository: AnalysisRepository
  private let defaults: UserDefaults
  private let logger = Logger(subsystem: "com.moolah.app", category: "AnalysisStore")

  init(repository: AnalysisRepository, defaults: UserDefaults = .standard) {
    self.repository = repository
    self.defaults = defaults

    // Restore last-used values (UserDefaults returns 0 for missing keys)
    let savedHistory = defaults.integer(forKey: "analysisHistoryMonths")
    self.historyMonths = savedHistory > 0 ? savedHistory : 12

    let savedForecast = defaults.integer(forKey: "analysisForecastMonths")
    // forecastMonths=0 means "None" which is valid, so only default if key is absent
    if defaults.object(forKey: "analysisForecastMonths") != nil {
      self.forecastMonths = savedForecast
    } else {
      self.forecastMonths = 1
    }
  }

  func loadAll() async {
    monthEnd = Calendar.current.component(.day, from: Date())
    isLoading = true
    error = nil

    do {
      let after = afterDate(monthsAgo: historyMonths)
      let forecastUntil = forecastDate(monthsAhead: forecastMonths)

      let data = try await repository.loadAll(
        historyAfter: after,
        forecastUntil: forecastUntil,
        monthEnd: monthEnd
      )

      dailyBalances = Self.extrapolateBalances(
        data.dailyBalances, today: Date(), forecastUntil: forecastUntil
      )
      expenseBreakdown = data.expenseBreakdown
      incomeAndExpense = data.incomeAndExpense.sorted { $0.month > $1.month }
    } catch {
      logger.error("Failed to load analysis data: \(error)")
      self.error = error
    }

    isLoading = false
  }

  /// Extends balance data to fill gaps, matching the web app's extrapolateBalances logic:
  /// 1. Extend actual balances forward to today (so the step chart reaches the present).
  /// 2. Extend forecast balances back to today (so forecast connects to actual data).
  /// 3. Extend forecast balances forward to the forecast end date.
  nonisolated static func extrapolateBalances(
    _ balances: [DailyBalance], today: Date, forecastUntil: Date?
  ) -> [DailyBalance] {
    let todayStart = Calendar.current.startOfDay(for: today)
    var actual = balances.filter { !$0.isForecast }
    var forecast = balances.filter { $0.isForecast }

    // Extend actual balances to today
    if let last = actual.last, Calendar.current.startOfDay(for: last.date) < todayStart {
      actual.append(last.withDate(todayStart))
    }

    // Extend forecast back to today (so forecast line starts where actual ends)
    if !forecast.isEmpty, let lastActual = actual.last {
      let firstForecastDay = Calendar.current.startOfDay(for: forecast[0].date)
      if firstForecastDay > todayStart {
        forecast.insert(lastActual.withDate(todayStart, isForecast: true), at: 0)
      }
    }

    // Extend forecast to the forecast end date
    if let forecastUntil, let last = forecast.last {
      let untilStart = Calendar.current.startOfDay(for: forecastUntil)
      if Calendar.current.startOfDay(for: last.date) < untilStart {
        forecast.append(last.withDate(untilStart))
      }
    }

    return (actual + forecast).sorted { $0.date < $1.date }
  }

  /// Transforms expense breakdown into chart-ready data grouped by root-level category and month.
  func categoriesOverTime(categories: Categories) -> [CategoryOverTimeEntry] {
    Self.buildCategoriesOverTime(from: expenseBreakdown, categories: categories)
  }

  /// Pure function for testability: transforms expense breakdown into chart-ready grouped data.
  /// Each category's expenses are rolled up to the root level, then sorted by total descending.
  static func buildCategoriesOverTime(
    from breakdown: [ExpenseBreakdown], categories: Categories
  ) -> [CategoryOverTimeEntry] {
    var rootTotals: [UUID?: [String: Int]] = [:]
    var allMonths: Set<String> = []

    // Negate totalExpenses (server returns negative for expenses) and clamp to zero,
    // matching the web app's categoryOverTimeData.js approach.
    for item in breakdown {
      let rootId = rootCategoryId(for: item.categoryId, categories: categories)
      allMonths.insert(item.month)
      rootTotals[rootId, default: [:]][item.month, default: 0] += -item.totalExpenses.cents
    }

    let orderedMonths = allMonths.sorted()

    var monthTotals: [String: Int] = [:]
    for (_, months) in rootTotals {
      for (month, cents) in months {
        monthTotals[month, default: 0] += max(0, cents)
      }
    }

    return rootTotals.map { categoryId, months in
      let points = orderedMonths.map { month -> CategoryOverTimePoint in
        let cents = max(0, months[month] ?? 0)
        let total = monthTotals[month] ?? 1
        let percentage = total > 0 ? Double(cents) / Double(total) * 100 : 0
        return CategoryOverTimePoint(
          month: month,
          monthDate: parseMonth(month),
          actualCents: cents,
          percentage: percentage
        )
      }
      let totalCents = months.values.reduce(0, +)
      return CategoryOverTimeEntry(
        categoryId: categoryId,
        points: points,
        totalCents: totalCents
      )
    }
    .sorted { $0.totalCents > $1.totalCents }
  }

  private static func rootCategoryId(for categoryId: UUID?, categories: Categories) -> UUID? {
    guard var id = categoryId else { return nil }
    while let category = categories.by(id: id), let parentId = category.parentId {
      id = parentId
    }
    return id
  }

  private static func parseMonth(_ month: String) -> Date {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMM"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: month) ?? Date.distantPast
  }

  /// Today's day-of-month, used as the financial month boundary (matching the web app).
  /// Stored so SwiftUI can observe changes (e.g. date rollover triggers reload).
  /// Updated at the start of each loadAll() call.
  private(set) var monthEnd: Int = Calendar.current.component(.day, from: Date())

  private func afterDate(monthsAgo: Int) -> Date? {
    guard monthsAgo > 0 else { return nil }  // 0 = "All"
    return Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date())
  }

  private func forecastDate(monthsAhead: Int) -> Date? {
    guard monthsAhead > 0 else { return nil }  // 0 = "None"
    return Calendar.current.date(byAdding: .month, value: monthsAhead, to: Date())
  }
}

struct CategoryOverTimePoint: Sendable, Identifiable {
  let month: String
  let monthDate: Date
  let actualCents: Int
  let percentage: Double

  var id: String { month }
}

struct CategoryOverTimeEntry: Sendable, Identifiable {
  let categoryId: UUID?
  let points: [CategoryOverTimePoint]
  let totalCents: Int

  var id: String { categoryId?.uuidString ?? "uncategorized" }
}
