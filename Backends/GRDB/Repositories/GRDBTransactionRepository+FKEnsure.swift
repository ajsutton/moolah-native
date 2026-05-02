// Backends/GRDB/Repositories/GRDBTransactionRepository+FKEnsure.swift

import Foundation
import GRDB

// Read-time instrument-resolution helper. Split out of
// `GRDBTransactionRepository` to keep the main class body under
// SwiftLint's `type_body_length` threshold.
//
// Non-fiat instrument rows must exist locally for `fetchAll` to
// resolve the full `Instrument` value when reading transactions. The
// `instrument_id` column has never had an FK and this helper has
// never been about FK enforcement for that column. Other parent
// references (`account_id`, `category_id`, `earmark_id`) had FKs in
// v3 that this helper used to dodge by inserting blank-name stubs
// when the parent CKRecord hadn't arrived yet. v5 dropped those FKs;
// the stubs are gone and a leg whose parent isn't in the local DB is
// allowed to land — see `guides/SYNC_GUIDE.md` "Per-profile schema
// does not enforce FKs" and the zombie-row trade-off documented in
// `ProfileSchema+DropForeignKeys.swift`.
extension GRDBTransactionRepository {
  /// Inserts a placeholder `instrument` row for any non-fiat
  /// instrument a leg references that isn't already present. Required
  /// so `fetchAll` can resolve the full `Instrument` domain value on
  /// read.
  static func ensureInstrumentReadable(
    database: Database,
    leg: TransactionLeg
  ) throws {
    guard leg.instrument.kind != .fiatCurrency else { return }
    let exists =
      try InstrumentRow
      .filter(InstrumentRow.Columns.id == leg.instrument.id)
      .fetchOne(database)
    guard exists == nil else { return }
    try InstrumentRow(domain: leg.instrument).insert(database)
  }
}
