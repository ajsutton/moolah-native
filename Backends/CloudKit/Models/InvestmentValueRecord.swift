import Foundation
import SwiftData

@Model
final class InvestmentValueRecord {
  #Unique<InvestmentValueRecord>([\.id])

  var id: UUID
  var accountId: UUID
  var date: Date
  var value: Int  // cents
  var currencyCode: String

  init(
    id: UUID = UUID(),
    accountId: UUID,
    date: Date,
    value: Int,
    currencyCode: String
  ) {
    self.id = id
    self.accountId = accountId
    self.date = date
    self.value = value
    self.currencyCode = currencyCode
  }

  func toDomain() -> InvestmentValue {
    let currency = Currency.from(code: currencyCode)
    return InvestmentValue(date: date, value: MonetaryAmount(cents: value, currency: currency))
  }
}
