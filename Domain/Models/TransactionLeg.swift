import Foundation

struct TransactionLeg: Codable, Sendable, Hashable {
  let accountId: UUID?
  let instrument: Instrument
  let quantity: Decimal
  let externalId: String?
  /// On-chain counterparty address (lowercased) for crypto wallet legs.
  /// `nil` for non-crypto legs and for legs whose source has no clear
  /// single counterparty (e.g. a contract-emitted multi-recipient airdrop,
  /// a self-send where both sides are this wallet, or a gas leg).
  ///
  /// Populated by `TransferEventBuilder` from the Alchemy transfer's
  /// `from` / `to` fields — whichever side is *not* this wallet. Decoded
  /// with `decodeIfPresent` so legacy rows (pre-#754) round-trip with
  /// `nil`.
  let counterpartyAddress: String?
  var type: TransactionType
  var categoryId: UUID?
  var earmarkId: UUID?

  init(
    accountId: UUID?,
    instrument: Instrument,
    quantity: Decimal,
    externalId: String? = nil,
    counterpartyAddress: String? = nil,
    type: TransactionType,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil
  ) {
    self.accountId = accountId
    self.instrument = instrument
    self.quantity = quantity
    self.externalId = externalId
    self.counterpartyAddress = counterpartyAddress
    self.type = type
    self.categoryId = categoryId
    self.earmarkId = earmarkId
  }

  /// Convenience: the quantity as an InstrumentAmount.
  var amount: InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: instrument)
  }
}
