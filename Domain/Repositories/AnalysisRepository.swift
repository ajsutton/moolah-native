import Foundation

/// Repository for fetching aggregated financial analysis data.
protocol AnalysisRepository: Sendable {
  /// Fetch daily balance snapshots for a date range, optionally including forecasts.
  ///
  /// - Parameters:
  ///   - after: Start date (inclusive). Nil = all history.
  ///   - forecastUntil: End date for forecast (inclusive). Nil = no forecast.
  /// - Returns: Array of DailyBalance (actual + forecast if requested).
  /// - Throws: BackendError on network/auth failure.
  func fetchDailyBalances(
    after: Date?,
    forecastUntil: Date?
  ) async throws -> [DailyBalance]

  /// Fetch expense breakdown by category for a date range.
  ///
  /// - Parameters:
  ///   - monthEnd: Day of month representing the user's financial month end (1–31).
  ///   - after: Start date (inclusive). Nil = all history.
  /// - Returns: Array of ExpenseBreakdown grouped by category and financial month.
  /// - Throws: BackendError on network/auth failure.
  func fetchExpenseBreakdown(
    monthEnd: Int,
    after: Date?
  ) async throws -> [ExpenseBreakdown]

  /// Fetch monthly income and expense summary for a date range.
  ///
  /// - Parameters:
  ///   - monthEnd: Day of month representing the user's financial month end (1–31).
  ///   - after: Start date (inclusive). Nil = all history.
  /// - Returns: Array of MonthlyIncomeExpense grouped by financial month.
  /// - Throws: BackendError on network/auth failure.
  func fetchIncomeAndExpense(
    monthEnd: Int,
    after: Date?
  ) async throws -> [MonthlyIncomeExpense]

  /// Fetch category balances (total amounts per category) for a date range and transaction type.
  ///
  /// Returns a flat dictionary mapping category IDs to total monetary amounts.
  /// The client is responsible for grouping subcategories under root categories.
  ///
  /// - Parameters:
  ///   - dateRange: Date range to analyze (inclusive on both ends).
  ///   - transactionType: Filter to 'income' or 'expense' transactions.
  ///   - filters: Optional additional filters (account, earmark, payee, etc.).
  /// - Returns: Dictionary where keys are category UUIDs and values are total MonetaryAmounts.
  /// - Throws: BackendError on network/auth failure.
  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?
  ) async throws -> [UUID: MonetaryAmount]
}
