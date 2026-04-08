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

  private let repository: AnalysisRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "AnalysisStore")

  init(repository: AnalysisRepository) {
    self.repository = repository
  }

  func loadAll() async {
    isLoading = true
    error = nil

    do {
      async let balances = loadDailyBalances()
      async let breakdown = loadExpenseBreakdown()
      async let income = loadIncomeAndExpense()

      _ = try await (balances, breakdown, income)
    } catch {
      logger.error("Failed to load analysis data: \(error.localizedDescription)")
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

  private func afterDate(monthsAgo: Int) -> Date? {
    guard monthsAgo > 0 else { return nil }  // 0 = "All"
    return Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date())
  }

  private func forecastDate(monthsAhead: Int) -> Date? {
    guard monthsAhead > 0 else { return nil }  // 0 = "None"
    return Calendar.current.date(byAdding: .month, value: monthsAhead, to: Date())
  }
}
