import Foundation

/// A single day's cumulative balance for a specific account.
/// Distinct from the analysis `DailyBalance` which aggregates across all accounts.
/// Used for the investment chart's "Invested Amount" line.
struct AccountDailyBalance: Codable, Sendable, Identifiable, Hashable {
  let date: Date
  let balance: InstrumentAmount

  var id: Date { date }
}
