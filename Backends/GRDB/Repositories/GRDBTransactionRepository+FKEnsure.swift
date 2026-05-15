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
  /// instrument a leg references that isn't already present. Returns
  /// the full `Instrument` value when an insert actually happened so
  /// the caller can fan it out to the shared registry AFTER the
  /// surrounding write commits; returns `nil` for fiat legs and for
  /// legs whose instrument was already in the per-profile copy.
  ///
  /// Required so `fetchAll` can resolve the full `Instrument` domain
  /// value on read against this profile's DB. The shared registry on
  /// the profile-index zone is the canonical source of cross-device
  /// truth; the auto-publish path (`onInstrumentChanged`) routes the
  /// returned `Instrument` through `registerStock` /
  /// `registerCrypto` so the row reaches CloudKit. Without the
  /// shared-registry fan-out, sibling devices would receive the leg
  /// but no `InstrumentRecord`, instrument-map resolution would fall
  /// back to `Instrument.fiat(code: id)`, and stock conversions would
  /// route through the fiat-only Frankfurter API and 404.
  static func ensureInstrumentReadable(
    database: Database,
    leg: TransactionLeg
  ) throws -> Instrument? {
    guard leg.instrument.kind != .fiatCurrency else { return nil }
    let exists =
      try InstrumentRow
      .filter(InstrumentRow.Columns.id == leg.instrument.id)
      .fetchOne(database)
    guard exists == nil else { return nil }
    try InstrumentRow(domain: leg.instrument).insert(database)
    return leg.instrument
  }
}
