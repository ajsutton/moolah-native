import Foundation

struct IncomeAndExpenseResponseDTO: Codable {
  let incomeAndExpense: [MonthlyIncomeExpenseDTO]
}

struct MonthlyIncomeExpenseDTO: Codable {
  let month: String  // "YYYYMM"
  let start: String  // "YYYY-MM-DD"
  let end: String  // "YYYY-MM-DD"
  let income: Int
  let expense: Int
  let profit: Int
  let earmarkedIncome: Int
  let earmarkedExpense: Int
  let earmarkedProfit: Int

  func toDomain() -> MonthlyIncomeExpense {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withFullDate]

    return MonthlyIncomeExpense(
      month: month,
      start: dateFormatter.date(from: start) ?? Date(),
      end: dateFormatter.date(from: end) ?? Date(),
      income: MonetaryAmount(cents: income, currency: .defaultCurrency),
      expense: MonetaryAmount(cents: expense, currency: .defaultCurrency),
      profit: MonetaryAmount(cents: profit, currency: .defaultCurrency),
      earmarkedIncome: MonetaryAmount(cents: earmarkedIncome, currency: .defaultCurrency),
      earmarkedExpense: MonetaryAmount(cents: earmarkedExpense, currency: .defaultCurrency),
      earmarkedProfit: MonetaryAmount(cents: earmarkedProfit, currency: .defaultCurrency)
    )
  }
}
