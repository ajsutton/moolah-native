import Foundation

struct IncomeAndExpenseResponseDTO: Codable {
  let incomeAndExpense: [MonthlyIncomeExpenseDTO]
}

struct MonthlyIncomeExpenseDTO: Codable {
  let month: Int  // YYYYMM (integer from server)
  let start: String  // "YYYY-MM-DD"
  let end: String  // "YYYY-MM-DD"
  let income: Int
  let expense: Int
  let profit: Int
  let earmarkedIncome: Int
  let earmarkedExpense: Int
  let earmarkedProfit: Int

  func toDomain() -> MonthlyIncomeExpense {
    return MonthlyIncomeExpense(
      month: String(month),
      start: BackendDateFormatter.date(from: start) ?? Date(),
      end: BackendDateFormatter.date(from: end) ?? Date(),
      income: MonetaryAmount(cents: income, currency: .defaultCurrency),
      expense: MonetaryAmount(cents: expense, currency: .defaultCurrency),
      profit: MonetaryAmount(cents: profit, currency: .defaultCurrency),
      earmarkedIncome: MonetaryAmount(cents: earmarkedIncome, currency: .defaultCurrency),
      earmarkedExpense: MonetaryAmount(cents: earmarkedExpense, currency: .defaultCurrency),
      earmarkedProfit: MonetaryAmount(cents: earmarkedProfit, currency: .defaultCurrency)
    )
  }
}
