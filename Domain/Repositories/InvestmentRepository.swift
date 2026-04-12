import Foundation

/// Repository for managing investment account valuations over time.
/// Values are keyed by (accountId, date) — one value per account per day.
protocol InvestmentRepository: Sendable {
  /// Fetch investment values for an account, sorted by date descending.
  /// - Parameters:
  ///   - accountId: The investment account to fetch values for
  ///   - page: Zero-indexed page number
  ///   - pageSize: Number of items per page
  /// - Returns: A page of investment values with hasMore flag
  func fetchValues(accountId: UUID, page: Int, pageSize: Int) async throws -> InvestmentValuePage

  /// Set the investment value for an account on a specific date (upsert).
  /// - Parameters:
  ///   - accountId: The investment account
  ///   - date: The valuation date
  ///   - value: The investment value
  func setValue(accountId: UUID, date: Date, value: InstrumentAmount) async throws

  /// Remove the investment value for an account on a specific date.
  /// - Parameters:
  ///   - accountId: The investment account
  ///   - date: The valuation date to remove
  func removeValue(accountId: UUID, date: Date) async throws

  /// Fetch daily cumulative balances for an account, sorted by date ascending.
  /// Each entry represents the running total of transactions up to that date.
  /// - Parameters:
  ///   - accountId: The account to fetch balances for
  /// - Returns: Array of daily balances sorted by date ascending
  func fetchDailyBalances(accountId: UUID) async throws -> [AccountDailyBalance]
}
