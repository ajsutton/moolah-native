import Foundation

struct TransactionLeg: Sendable {
  let id: UUID
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
  /// with `decodeIfPresent` so rows persisted without the field
  /// round-trip with `nil`.
  let counterpartyAddress: String?
  var type: TransactionType
  var categoryId: UUID?
  var earmarkId: UUID?

  init(
    id: UUID = UUID(),
    accountId: UUID?,
    instrument: Instrument,
    quantity: Decimal,
    externalId: String? = nil,
    counterpartyAddress: String? = nil,
    type: TransactionType,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil
  ) {
    self.id = id
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

extension TransactionLeg: Identifiable {}

extension TransactionLeg: Hashable {}

extension TransactionLeg: Codable {
  private enum CodingKeys: String, CodingKey {
    case id
    case accountId
    case instrument
    case quantity
    case externalId
    case counterpartyAddress
    case type
    case categoryId
    case earmarkId
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Rows without a persisted id get a freshly allocated one; rows with a
    // persisted id keep their stable id assigned at creation time.
    self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    self.accountId = try container.decodeIfPresent(UUID.self, forKey: .accountId)
    self.instrument = try container.decode(Instrument.self, forKey: .instrument)
    self.quantity = try container.decode(Decimal.self, forKey: .quantity)
    self.externalId = try container.decodeIfPresent(String.self, forKey: .externalId)
    self.counterpartyAddress = try container.decodeIfPresent(
      String.self, forKey: .counterpartyAddress)
    self.type = try container.decode(TransactionType.self, forKey: .type)
    self.categoryId = try container.decodeIfPresent(UUID.self, forKey: .categoryId)
    self.earmarkId = try container.decodeIfPresent(UUID.self, forKey: .earmarkId)
  }
}
