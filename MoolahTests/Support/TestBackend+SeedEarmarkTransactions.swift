import Foundation
import GRDB

@testable import Moolah

// `seedWithTransactions(...)` and its private leg-insertion helper —
// split out of `TestBackend.swift` so that file's enum body stays under
// SwiftLint's `type_body_length` threshold.
extension TestBackend {
  /// Identifies an earmark transaction leg to seed alongside its earmark row.
  /// Bundles the per-call parameters that vary between the saved/spent paths
  /// in `seedWithTransactions(earmarks:amounts:accountId:in:instrument:)` —
  /// keeps `insertEarmarkLeg`'s parameter count under SwiftLint's threshold.
  struct EarmarkLegSpec {
    let accountId: UUID
    let instrument: Instrument
    let quantity: Decimal
    let type: TransactionType
    let earmarkId: UUID
  }

  /// Seeds earmarks along with transactions that produce the desired saved/spent values.
  /// `amounts` maps earmark ID to (saved, spent) quantities as Decimals.
  /// If an earmark has no entry in amounts, no transactions are created.
  @discardableResult
  static func seedWithTransactions(
    earmarks: [Earmark],
    amounts: [UUID: (saved: Decimal, spent: Decimal)] = [:],
    accountId: UUID,
    in database: any DatabaseWriter,
    instrument: Instrument = .defaultTestInstrument
  ) -> [Earmark] {
    do {
      try database.write { database in
        // Auto-seed the parent account if no test seeded it explicitly.
        // The existing SwiftData-era pattern relied on FK enforcement
        // being absent; under the GRDB schema the parent row must exist
        // before the leg insert hits the FK on `transaction_leg.account_id`.
        let exists =
          try AccountRow.filter(AccountRow.Columns.id == accountId).fetchOne(database)
        if exists == nil {
          let stub = Account(
            id: accountId, name: "stub", type: .bank, instrument: instrument)
          try AccountRow(domain: stub).insert(database)
        }
        for earmark in earmarks {
          try seedEarmarkWithTransactions(
            earmark: earmark,
            amounts: amounts,
            accountId: accountId,
            instrument: instrument,
            database: database)
        }
      }
    } catch {
      preconditionFailure("TestBackend seedWithTransactions failed: \(error)")
    }
    return earmarks
  }

  static func seedEarmarkWithTransactions(
    earmark: Earmark,
    amounts: [UUID: (saved: Decimal, spent: Decimal)],
    accountId: UUID,
    instrument: Instrument,
    database: Database
  ) throws {
    try EarmarkRow(domain: earmark).insert(database)
    let earmarkAmounts = amounts[earmark.id]
    let savedQty = earmarkAmounts?.saved ?? 0
    let spentQty = earmarkAmounts?.spent ?? 0
    if savedQty != 0 {
      try insertEarmarkLeg(
        database: database,
        spec: EarmarkLegSpec(
          accountId: accountId,
          instrument: instrument,
          quantity: savedQty,
          type: .income,
          earmarkId: earmark.id))
    }
    if spentQty != 0 {
      try insertEarmarkLeg(
        database: database,
        spec: EarmarkLegSpec(
          accountId: accountId,
          instrument: instrument,
          quantity: -spentQty,
          type: .expense,
          earmarkId: earmark.id))
    }
  }

  static func insertEarmarkLeg(
    database: Database,
    spec: EarmarkLegSpec
  ) throws {
    let txnId = UUID()
    let txnRow = TransactionRow(
      id: txnId,
      recordName: TransactionRow.recordName(for: txnId),
      date: Date(),
      payee: nil,
      notes: nil,
      recurPeriod: nil,
      recurEvery: nil,
      importOriginRawDescription: nil,
      importOriginBankReference: nil,
      importOriginRawAmount: nil,
      importOriginRawBalance: nil,
      importOriginImportedAt: nil,
      importOriginImportSessionId: nil,
      importOriginSourceFilename: nil,
      importOriginParserIdentifier: nil,
      encodedSystemFields: nil)
    try txnRow.insert(database)
    let legId = UUID()
    let legRow = TransactionLegRow(
      id: legId,
      recordName: TransactionLegRow.recordName(for: legId),
      transactionId: txnId,
      accountId: spec.accountId,
      instrumentId: spec.instrument.id,
      quantity: InstrumentAmount(
        quantity: spec.quantity, instrument: spec.instrument
      ).storageValue,
      type: spec.type.rawValue,
      categoryId: nil,
      earmarkId: spec.earmarkId,
      sortOrder: 0,
      encodedSystemFields: nil)
    try legRow.insert(database)
  }
}
