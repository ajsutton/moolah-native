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

  func toDomain(currency: Currency) -> MonthlyIncomeExpense {
    return MonthlyIncomeExpense(
      month: String(month),
      start: BackendDateFormatter.date(from: start) ?? Date(),
      end: BackendDateFormatter.date(from: end) ?? Date(),
      income: MonetaryAmount(cents: income, currency: currency),
      expense: MonetaryAmount(cents: expense, currency: currency),
      profit: MonetaryAmount(cents: profit, currency: currency),
      earmarkedIncome: MonetaryAmount(cents: earmarkedIncome, currency: currency),
      earmarkedExpense: MonetaryAmount(cents: earmarkedExpense, currency: currency),
      earmarkedProfit: MonetaryAmount(cents: earmarkedProfit, currency: currency)
    )
  }
}
