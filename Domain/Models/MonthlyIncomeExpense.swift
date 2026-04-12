import Foundation

/// Aggregated income and expenses for one financial month.
struct MonthlyIncomeExpense: Sendable, Codable, Identifiable, Hashable {
  var id: String { month }

  /// Financial month in YYYYMM format (e.g., "202604")
  let month: String

  /// First transaction date in this financial month (for display)
  let start: Date

  /// Last transaction date in this financial month (for display)
  let end: Date

  // --- Non-earmarked income & expenses ---

  /// Total income (excluding earmarked income) in cents
  let income: InstrumentAmount

  /// Total expenses (excluding earmarked expenses) in cents
  let expense: InstrumentAmount

  /// Profit = income - expense (can be negative)
  let profit: InstrumentAmount

  // --- Earmarked income & expenses ---

  /// Income allocated to earmarks (including investment contributions)
  let earmarkedIncome: InstrumentAmount

  /// Expenses paid from earmarks (including investment withdrawals)
  let earmarkedExpense: InstrumentAmount

  /// Earmarked profit = earmarkedIncome - earmarkedExpense
  let earmarkedProfit: InstrumentAmount
}

extension MonthlyIncomeExpense {
  /// Compute total income (including earmarks)
  var totalIncome: InstrumentAmount {
    income + earmarkedIncome
  }

  /// Compute total expenses (including earmarks)
  var totalExpense: InstrumentAmount {
    expense + earmarkedExpense
  }

  /// Compute total profit (including earmarks)
  var totalProfit: InstrumentAmount {
    profit + earmarkedProfit
  }
}
