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

  func toDomain(instrument: Instrument) -> MonthlyIncomeExpense {
    return MonthlyIncomeExpense(
      month: String(month),
      start: BackendDateFormatter.date(from: start) ?? Date(),
      end: BackendDateFormatter.date(from: end) ?? Date(),
      income: InstrumentAmount(quantity: Decimal(income) / 100, instrument: instrument),
      expense: InstrumentAmount(quantity: Decimal(expense) / 100, instrument: instrument),
      profit: InstrumentAmount(quantity: Decimal(profit) / 100, instrument: instrument),
      earmarkedIncome: InstrumentAmount(
        quantity: Decimal(earmarkedIncome) / 100, instrument: instrument),
      earmarkedExpense: InstrumentAmount(
        quantity: Decimal(earmarkedExpense) / 100, instrument: instrument),
      earmarkedProfit: InstrumentAmount(
        quantity: Decimal(earmarkedProfit) / 100, instrument: instrument)
    )
  }
}
