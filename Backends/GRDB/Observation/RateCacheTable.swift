// Backends/GRDB/Observation/RateCacheTable.swift

import Foundation
import GRDB

/// The three live rate-cache tables observed by
/// `InstrumentConversionService.observeRates()`. All three are
/// declared `WITHOUT ROWID` in `ProfileSchema+RateCaches.swift` /
/// `ProfileSchema+RateCacheWithoutRowid.swift` for storage efficiency
/// (single-TEXT-PK lookup tables per
/// `guides/DATABASE_SCHEMA_GUIDE.md` §3).
enum RateCacheTable: String, Sendable {
  case exchangeRate = "exchange_rate"
  case stockPrice = "stock_price"
  case cryptoPrice = "crypto_price"
}

extension Database {
  /// Notifies GRDB's transaction observer that one of the live
  /// rate-cache tables changed. Required because the rate-cache tables
  /// are declared `WITHOUT ROWID`, and SQLite's `sqlite3_update_hook`
  /// does not fire for such tables (a documented SQLite limitation —
  /// see GRDB's `ValueObservation.md`). Without this synthesised
  /// notification, `ValueObservation.tracking(regions:fetch:)` over
  /// these tables registers the regions but never re-fires after a
  /// write — every `observeRates()` subscription would hang on the
  /// initial tick.
  ///
  /// Call inside the same `db.write { ... }` block as the actual
  /// inserts / updates / deletes, **after** the writes execute. The
  /// notification is folded into the transaction's observer events; if
  /// the transaction rolls back, no notification is emitted.
  ///
  /// See `guides/DATABASE_CODE_GUIDE.md` §2 convention 1 for the
  /// `WITHOUT ROWID` interaction with `ValueObservation`.
  func notifyRateCacheChange(_ table: RateCacheTable) throws {
    try notifyChanges(in: Table(table.rawValue))
  }
}
