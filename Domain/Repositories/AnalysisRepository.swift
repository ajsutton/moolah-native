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
  ///   - targetInstrument: Instrument to convert the aggregated amounts into. Callers that
  ///     filter by earmark should pass the earmark's instrument so the totals are directly
  ///     comparable to the earmark's budget items (see
  ///     `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 1/2). Single-instrument backends
  ///     require this to match the profile instrument.
  /// - Returns: Dictionary where keys are category UUIDs and values are total
  ///   `InstrumentAmount`s in `targetInstrument`.
  /// - Throws: BackendError on network/auth failure.
  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> [UUID: InstrumentAmount]

  /// Fetch category balances for both income and expense in a single pass.
  ///
  /// More efficient than calling `fetchCategoryBalances` twice because backends that
  /// compute locally only need to load and filter transactions once.
  ///
  /// - Parameters:
  ///   - dateRange: Date range to analyze (inclusive on both ends).
  ///   - filters: Optional additional filters (account, earmark, payee, etc.).
  ///   - targetInstrument: Instrument the aggregated amounts are expressed in.
  /// - Returns: Tuple of income and expense dictionaries mapping category UUIDs to totals.
  /// - Throws: BackendError on network/auth failure.
  func fetchCategoryBalancesByType(
    dateRange: ClosedRange<Date>,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> (income: [UUID: InstrumentAmount], expense: [UUID: InstrumentAmount])

  /// Load all analysis data in a single batch, avoiding redundant fetches.
  ///
  /// Backends that compute locally (CloudKit/SwiftData) should override this to fetch
  /// shared data once. The default implementation calls the three individual methods.
  func loadAll(
    historyAfter: Date?,
    forecastUntil: Date?,
    monthEnd: Int
  ) async throws -> AnalysisData
}

/// Result of loading all analysis data in a single batch.
/// Used to avoid redundant data fetching in backends that compute locally (e.g. CloudKit).
struct AnalysisData: Sendable {
  let dailyBalances: [DailyBalance]
  let expenseBreakdown: [ExpenseBreakdown]
  let incomeAndExpense: [MonthlyIncomeExpense]
}

extension AnalysisRepository {
  func fetchCategoryBalancesByType(
    dateRange: ClosedRange<Date>,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> (income: [UUID: InstrumentAmount], expense: [UUID: InstrumentAmount]) {
    async let incomeResult = fetchCategoryBalances(
      dateRange: dateRange, transactionType: .income, filters: filters,
      targetInstrument: targetInstrument)
    async let expenseResult = fetchCategoryBalances(
      dateRange: dateRange, transactionType: .expense, filters: filters,
      targetInstrument: targetInstrument)
    return try await (income: incomeResult, expense: expenseResult)
  }

  func loadAll(
    historyAfter: Date?,
    forecastUntil: Date?,
    monthEnd: Int
  ) async throws -> AnalysisData {
    async let balances = fetchDailyBalances(after: historyAfter, forecastUntil: forecastUntil)
    async let breakdown = fetchExpenseBreakdown(monthEnd: monthEnd, after: historyAfter)
    async let income = fetchIncomeAndExpense(monthEnd: monthEnd, after: historyAfter)

    return try await AnalysisData(
      dailyBalances: balances,
      expenseBreakdown: breakdown,
      incomeAndExpense: income
    )
  }
}
