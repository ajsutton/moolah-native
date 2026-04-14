import Foundation
import SwiftData

@Model
final class EarmarkRecord {

  #Index<EarmarkRecord>([\.id])

  var id: UUID = UUID()
  var name: String = ""
  var position: Int = 0
  var isHidden: Bool = false
  var savingsTarget: Int?  // cents
  var currencyCode: String = ""
  var savingsStartDate: Date?
  var savingsEndDate: Date?
  var encodedSystemFields: Data?

  init(
    id: UUID = UUID(),
    name: String,
    position: Int = 0,
    isHidden: Bool = false,
    savingsTarget: Int? = nil,
    currencyCode: String,
    savingsStartDate: Date? = nil,
    savingsEndDate: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.position = position
    self.isHidden = isHidden
    self.savingsTarget = savingsTarget
    self.currencyCode = currencyCode
    self.savingsStartDate = savingsStartDate
    self.savingsEndDate = savingsEndDate
  }

  func toDomain(balance: MonetaryAmount, saved: MonetaryAmount, spent: MonetaryAmount) -> Earmark {
    let currency = Currency.from(code: currencyCode)
    return Earmark(
      id: id,
      name: name,
      balance: balance,
      saved: saved,
      spent: spent,
      isHidden: isHidden,
      position: position,
      savingsGoal: savingsTarget.map { MonetaryAmount(cents: $0, currency: currency) },
      savingsStartDate: savingsStartDate,
      savingsEndDate: savingsEndDate
    )
  }

  static func from(_ earmark: Earmark, currencyCode: String) -> EarmarkRecord {
    EarmarkRecord(
      id: earmark.id,
      name: earmark.name,
      position: earmark.position,
      isHidden: earmark.isHidden,
      savingsTarget: earmark.savingsGoal?.cents,
      currencyCode: currencyCode,
      savingsStartDate: earmark.savingsStartDate,
      savingsEndDate: earmark.savingsEndDate
    )
  }
}
