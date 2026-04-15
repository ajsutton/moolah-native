import Foundation

/// Represents a single point-in-time valuation of an investment account.
/// Values are uniquely identified by (accountId, date) — one value per account per day.
struct InvestmentValue: Codable, Sendable, Identifiable, Hashable, Comparable {
  let date: Date
  let value: InstrumentAmount

  /// Uses date as identity since values are unique per account per day.
  var id: Date { date }

  /// Sort by date descending (newest first).
  static func < (lhs: InvestmentValue, rhs: InvestmentValue) -> Bool {
    lhs.date > rhs.date
  }
}

/// A page of investment values with pagination metadata.
struct InvestmentValuePage: Sendable {
  let values: [InvestmentValue]
  let hasMore: Bool
}
