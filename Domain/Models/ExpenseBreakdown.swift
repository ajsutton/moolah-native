import Foundation

/// Aggregated expenses for one category in one financial month.
struct ExpenseBreakdown: Sendable, Codable, Identifiable, Hashable {
  var id: String { "\(categoryId?.uuidString ?? "uncategorized")-\(month)" }

  /// The category (nil means uncategorized expenses)
  let categoryId: UUID?

  /// Financial month in YYYYMM format (e.g., "202604" for April 2026 financial month)
  /// Grouped by user's monthEnd preference (e.g., Jan 26 – Feb 25 = "202602")
  let month: String

  /// Total expenses in cents (always positive, sum of transaction amounts)
  let totalExpenses: MonetaryAmount
}

extension ExpenseBreakdown {
  /// Parse month string to Date (first day of calendar month)
  var monthDate: Date? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMM"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: month)
  }
}
