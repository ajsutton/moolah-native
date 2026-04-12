import Foundation
import SwiftData

@Model
final class TransactionLegRecord {
  var id: UUID = UUID()
  var transactionId: UUID = UUID()
  var accountId: UUID = UUID()
  var instrumentId: String = ""
  var quantity: Int64 = 0  // Actual value × 10^8
  var type: String = "expense"
  var categoryId: UUID?
  var earmarkId: UUID?
  var sortOrder: Int = 0

  init(
    id: UUID = UUID(),
    transactionId: UUID,
    accountId: UUID,
    instrumentId: String,
    quantity: Int64,
    type: String,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil,
    sortOrder: Int = 0
  ) {
    self.id = id
    self.transactionId = transactionId
    self.accountId = accountId
    self.instrumentId = instrumentId
    self.quantity = quantity
    self.type = type
    self.categoryId = categoryId
    self.earmarkId = earmarkId
    self.sortOrder = sortOrder
  }

  func toDomain(instrument: Instrument) -> TransactionLeg {
    TransactionLeg(
      accountId: accountId,
      instrument: instrument,
      quantity: InstrumentAmount(storageValue: quantity, instrument: instrument).quantity,
      type: TransactionType(rawValue: type) ?? .expense,
      categoryId: categoryId,
      earmarkId: earmarkId
    )
  }

  static func from(_ leg: TransactionLeg, transactionId: UUID, sortOrder: Int)
    -> TransactionLegRecord
  {
    TransactionLegRecord(
      transactionId: transactionId,
      accountId: leg.accountId,
      instrumentId: leg.instrument.id,
      quantity: InstrumentAmount(quantity: leg.quantity, instrument: leg.instrument).storageValue,
      type: leg.type.rawValue,
      categoryId: leg.categoryId,
      earmarkId: leg.earmarkId,
      sortOrder: sortOrder
    )
  }
}
