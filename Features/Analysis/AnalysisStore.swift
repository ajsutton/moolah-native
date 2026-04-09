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

  // Filters
  var historyMonths: Int = 12  // 1, 3, 6, 12, 24, 36, etc., or 0 = "All"
  var forecastMonths: Int = 1  // 0 = "None", 1, 3, 6, etc.
  var monthEnd: Int = 25  // User's financial month-end day (1-31)
  var showActualValues: Bool = false  // false = percentage, true = actual amounts

  let repository: AnalysisRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "AnalysisStore")

  init(repository: AnalysisRepository) {
    self.repository = repository
  }

  func loadAll() async {
    isLoading = true
    error = nil

    do {
      async let balances: Void = loadDailyBalances()
      async let breakdown: Void = loadExpenseBreakdown()
      async let income: Void = loadIncomeAndExpense()

      _ = try await (balances, breakdown, income)
    } catch {
      logger.error("Failed to load analysis data: \(error)")
      self.error = error
    }

    isLoading = false
  }

  private func loadDailyBalances() async throws {
    let after = afterDate(monthsAgo: historyMonths)
    let forecastUntil = forecastDate(monthsAhead: forecastMonths)

    dailyBalances = try await repository.fetchDailyBalances(
      after: after,
      forecastUntil: forecastUntil
    )
  }

  private func loadExpenseBreakdown() async throws {
    let after = afterDate(monthsAgo: historyMonths)

    expenseBreakdown = try await repository.fetchExpenseBreakdown(
      monthEnd: monthEnd,
      after: after
    )
  }

  private func loadIncomeAndExpense() async throws {
    let after = afterDate(monthsAgo: historyMonths)

    incomeAndExpense = try await repository.fetchIncomeAndExpense(
      monthEnd: monthEnd,
      after: after
    )
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

    for item in breakdown {
      let rootId = rootCategoryId(for: item.categoryId, categories: categories)
      allMonths.insert(item.month)
      rootTotals[rootId, default: [:]][item.month, default: 0] += item.totalExpenses.cents
    }

    let orderedMonths = allMonths.sorted()

    var monthTotals: [String: Int] = [:]
    for (_, months) in rootTotals {
      for (month, cents) in months {
        monthTotals[month, default: 0] += cents
      }
    }

    return rootTotals.map { categoryId, months in
      let points = orderedMonths.map { month -> CategoryOverTimePoint in
        let cents = months[month] ?? 0
        let total = monthTotals[month] ?? 1
        let percentage = total != 0 ? Double(cents) / Double(total) * 100 : 0
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
    .sorted { abs($0.totalCents) > abs($1.totalCents) }
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
