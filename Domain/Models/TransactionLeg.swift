import Foundation

struct TransactionLeg: Codable, Sendable, Hashable {
  let accountId: UUID?
  let instrument: Instrument
  let quantity: Decimal
  var type: TransactionType
  var categoryId: UUID?
  var earmarkId: UUID?

  init(
    accountId: UUID?,
    instrument: Instrument,
    quantity: Decimal,
    type: TransactionType,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil
  ) {
    self.accountId = accountId
    self.instrument = instrument
    self.quantity = quantity
    self.type = type
    self.categoryId = categoryId
    self.earmarkId = earmarkId
  }

  /// Convenience: the quantity as an InstrumentAmount.
  var amount: InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: instrument)
  }
}
