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

  /// Streams `InvestmentValuePage` snapshots for `accountId` whenever the
  /// underlying `investment_value` table changes. Initial value is the
  /// current DB state. The supplied `accountId`, `page`, and `pageSize`
  /// are captured into the tracking closure — changing any of them
  /// requires cancelling the prior subscription and starting a new one.
  func observeValues(
    accountId: UUID, page: Int, pageSize: Int
  ) -> AsyncStream<InvestmentValuePage>

  /// Streams `[AccountDailyBalance]` snapshots for `accountId` whenever
  /// the underlying transaction tables change. Initial value is the
  /// current DB state. Captures `accountId` into the tracking closure.
  func observeDailyBalances(accountId: UUID) -> AsyncStream<[AccountDailyBalance]>

  /// Tick stream that yields `()` whenever any row in `investment_value`
  /// changes (across all accounts). Consumed by `AccountStore` so a
  /// remote-sync write to an investment value reaches the sidebar
  /// without requiring a per-account subscription. Initial tick fires
  /// after the first observation establishes; subsequent ticks fire on
  /// each commit.
  func observeAllValues() -> AsyncStream<Void>

  /// Companion error stream — surfaces non-recoverable observation errors
  /// once, then finishes. Mirrors `AccountRepository.observeErrors()`.
  func observeErrors() -> AsyncStream<any Error>
}
