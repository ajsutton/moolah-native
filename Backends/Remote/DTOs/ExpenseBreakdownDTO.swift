import Foundation

struct ExpenseBreakdownDTO: Codable {
  let categoryId: ServerUUID?  // UUID string (may or may not have dashes) or null
  let month: Int  // YYYYMM (integer from server)
  let totalExpenses: Int

  func toDomain(currency: Currency) -> ExpenseBreakdown {
    ExpenseBreakdown(
      categoryId: categoryId?.uuid,
      month: String(month),
      totalExpenses: MonetaryAmount(cents: totalExpenses, currency: currency)
    )
  }
}
