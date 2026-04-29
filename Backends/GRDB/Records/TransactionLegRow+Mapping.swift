// Backends/GRDB/Records/TransactionLegRow+Mapping.swift

import Foundation

extension TransactionLegRow {
  /// The CloudKit recordType on the wire for this record. Frozen contract.
  static let recordType = "TransactionLegRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed transaction leg.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  /// Builds a row from a domain `TransactionLeg`. Mirrors
  /// `TransactionLegRecord.from(_:transactionId:sortOrder:)`.
  /// `TransactionLeg` does not own its own UUID, so the caller supplies
  /// `id`, `transactionId`, and `sortOrder`. Pass an existing leg id
  /// when round-tripping (replace-legs path); pass a fresh `UUID()` on
  /// initial create.
  init(
    id: UUID = UUID(),
    domain leg: TransactionLeg,
    transactionId: UUID,
    sortOrder: Int
  ) {
    self.id = id
    self.recordName = Self.recordName(for: id)
    self.transactionId = transactionId
    self.accountId = leg.accountId
    self.instrumentId = leg.instrument.id
    self.quantity =
      InstrumentAmount(quantity: leg.quantity, instrument: leg.instrument).storageValue
    self.type = leg.type.rawValue
    self.categoryId = leg.categoryId
    self.earmarkId = leg.earmarkId
    self.sortOrder = sortOrder
    self.encodedSystemFields = nil
  }

  /// Domain projection. Mirrors `TransactionLegRecord.toDomain(instrument:)`.
  /// `instrument` must be supplied by the repository via the registry
  /// lookup; the row itself only stores the id.
  ///
  /// Throws `BackendError.dataCorrupted` when `type` carries a raw value
  /// the compiled `TransactionType` enum doesn't recognise — see
  /// `TransactionType.decoded(rawValue:)`.
  func toDomain(instrument: Instrument) throws -> TransactionLeg {
    TransactionLeg(
      accountId: accountId,
      instrument: instrument,
      quantity: InstrumentAmount(storageValue: quantity, instrument: instrument).quantity,
      type: try TransactionType.decoded(rawValue: type),
      categoryId: categoryId,
      earmarkId: earmarkId
    )
  }
}
