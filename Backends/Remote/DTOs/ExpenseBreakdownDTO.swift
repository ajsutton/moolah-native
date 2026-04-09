import Foundation

struct ExpenseBreakdownDTO: Codable {
  let categoryId: String?  // UUID string (may or may not have dashes) or null
  let month: Int  // YYYYMM (integer from server)
  let totalExpenses: Int

  func toDomain() -> ExpenseBreakdown {
    ExpenseBreakdown(
      categoryId: categoryId.flatMap { FlexibleUUID.parse($0) },
      month: String(month),
      totalExpenses: MonetaryAmount(cents: totalExpenses, currency: .defaultCurrency)
    )
  }
}
