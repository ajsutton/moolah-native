import Foundation
import SwiftData

@Model
final class EarmarkBudgetItemRecord {
  #Unique<EarmarkBudgetItemRecord>([\.id])

  var id: UUID
  var earmarkId: UUID
  var categoryId: UUID
  var amount: Int  // cents
  var currencyCode: String

  init(
    id: UUID = UUID(),
    earmarkId: UUID,
    categoryId: UUID,
    amount: Int,
    currencyCode: String
  ) {
    self.id = id
    self.earmarkId = earmarkId
    self.categoryId = categoryId
    self.amount = amount
    self.currencyCode = currencyCode
  }

  func toDomain() -> EarmarkBudgetItem {
    let currency = Currency.from(code: currencyCode)
    return EarmarkBudgetItem(
      id: id, categoryId: categoryId, amount: MonetaryAmount(cents: amount, currency: currency))
  }
}
