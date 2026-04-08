import Foundation

struct ExpenseBreakdownDTO: Codable {
  let categoryId: String?  // UUID string or null
  let month: String  // "YYYYMM"
  let totalExpenses: Int

  func toDomain() -> ExpenseBreakdown {
    ExpenseBreakdown(
      categoryId: categoryId.flatMap { UUID(uuidString: $0) },
      month: month,
      totalExpenses: MonetaryAmount(cents: totalExpenses, currency: .defaultCurrency)
    )
  }
}
