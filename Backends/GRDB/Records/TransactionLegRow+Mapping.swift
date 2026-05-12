// Backends/GRDB/Records/TransactionLegRow+Mapping.swift

import Foundation

extension TransactionLegRow {
  /// The CloudKit recordType on the wire for this record. Frozen contract.
  static let recordType = "TransactionLegRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed transaction leg.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  /// Builds a row from a domain `TransactionLeg`. The row's `id` defaults
  /// to `leg.id` (the leg's stable domain id). Callers can override `id`
  /// only if they need a row id that differs from the leg's own stable
  /// id — no in-tree callsite needs that. Passing `leg.id` explicitly
  /// (as `create(_:)` does, for callsite-clarity) is also fine; the
  /// default and the explicit value are identical. The CK-ingestion
  /// path constructs `TransactionLegRow` via the memberwise init in
  /// `TransactionLegRow+CloudKit.fieldValues(from:)`, not this factory.
  init(
    id: UUID? = nil,
    domain leg: TransactionLeg,
    transactionId: UUID,
    sortOrder: Int
  ) {
    let resolvedId = id ?? leg.id
    self.id = resolvedId
    self.recordName = Self.recordName(for: resolvedId)
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
    self.externalId = leg.externalId
    self.counterpartyAddress = leg.counterpartyAddress
  }

  /// Domain projection. `instrument` must be supplied by the repository
  /// via the registry lookup; the row itself only stores the id.
  ///
  /// Throws `BackendError.dataCorrupted` when `type` carries a raw value
  /// the compiled `TransactionType` enum doesn't recognise — see
  /// `TransactionType.decoded(rawValue:)`.
  func toDomain(instrument: Instrument) throws -> TransactionLeg {
    TransactionLeg(
      id: id,
      accountId: accountId,
      instrument: instrument,
      quantity: InstrumentAmount(storageValue: quantity, instrument: instrument).quantity,
      externalId: externalId,
      counterpartyAddress: counterpartyAddress,
      type: try TransactionType.decoded(rawValue: type),
      categoryId: categoryId,
      earmarkId: earmarkId
    )
  }
}
