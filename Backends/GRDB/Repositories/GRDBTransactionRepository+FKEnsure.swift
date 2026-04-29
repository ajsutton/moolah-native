// Backends/GRDB/Repositories/GRDBTransactionRepository+FKEnsure.swift

import Foundation
import GRDB

// FK-target placeholder helpers. Split out of `GRDBTransactionRepository`
// so the main class body stays under SwiftLint's `type_body_length`
// threshold. Production callers always pass ids that correspond to
// fetched parents; sync-race scenarios (a leg's CKRecord arrives before
// its account / category / earmark / instrument) would otherwise reject
// the legit insert under SQLite's enforced FKs. Materialising
// placeholders lets the parent's own remote insert upsert in place once
// it lands. Placeholder rows are also necessary for non-fiat instruments
// so `fetchAll` can resolve the full `Instrument` value on read.
extension GRDBTransactionRepository {
  /// Inserts placeholder rows for any FK target a leg references that
  /// isn't already present (`account`, `category`, `earmark`,
  /// `instrument`).
  static func ensureFKTargets(
    database: Database,
    leg: TransactionLeg,
    defaultInstrument: Instrument
  ) throws {
    if leg.instrument.kind != .fiatCurrency {
      let exists =
        try InstrumentRow
        .filter(InstrumentRow.Columns.id == leg.instrument.id)
        .fetchOne(database)
      if exists == nil {
        try InstrumentRow(domain: leg.instrument).insert(database)
      }
    }
    if let accountId = leg.accountId {
      let exists =
        try AccountRow
        .filter(AccountRow.Columns.id == accountId)
        .fetchOne(database)
      if exists == nil {
        let stub = Account(
          id: accountId, name: "", type: .bank, instrument: defaultInstrument)
        try AccountRow(domain: stub).insert(database)
      }
    }
    if let categoryId = leg.categoryId {
      let exists =
        try CategoryRow
        .filter(CategoryRow.Columns.id == categoryId)
        .fetchOne(database)
      if exists == nil {
        try CategoryRow(domain: Moolah.Category(id: categoryId, name: "")).insert(database)
      }
    }
    if let earmarkId = leg.earmarkId {
      let exists =
        try EarmarkRow
        .filter(EarmarkRow.Columns.id == earmarkId)
        .fetchOne(database)
      if exists == nil {
        let stub = Earmark(id: earmarkId, name: "", instrument: defaultInstrument)
        try EarmarkRow(domain: stub).insert(database)
      }
    }
  }
}
