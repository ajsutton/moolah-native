import Foundation
import SwiftData

@Model
final class InvestmentValueRecord {

  #Index<InvestmentValueRecord>([\.id], [\.accountId])

  var id: UUID = UUID()
  var accountId: UUID = UUID()
  var date: Date = Date()
  var value: Int = 0  // cents
  var currencyCode: String = ""
  var encodedSystemFields: Data?

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
