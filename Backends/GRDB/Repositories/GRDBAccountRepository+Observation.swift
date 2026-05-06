// Backends/GRDB/Repositories/GRDBAccountRepository+Observation.swift

import Foundation
import GRDB
import OSLog

private let logger = Logger(
  subsystem: "com.moolah.app", category: "GRDBAccountRepository")

// Reactive observation surface for `AccountRepository`. Split out of the
// main class file to keep `GRDBAccountRepository.swift` under SwiftLint's
// `file_length` warning threshold and to mirror the established
// `+Positions.swift` companion-file pattern.
//
// `observeAll()` returns the same domain projection as `fetchAll()`:
// account rows ordered by `position`, each populated with its full
// `Instrument` value and per-instrument `Position` totals computed from
// non-scheduled `transaction_leg` rows.
//
// `observeErrors()` exposes the shared `ObservationErrorChannel.stream`
// declared on the repo instance (see `GRDBAccountRepository.swift`).
// The bridge contracts (single-shot, no retry, surface-then-finish) are
// documented on `AsyncValueObservation.toAsyncStream(onError:)` and on
// `ObservationErrorChannel.surfaceAndFinish(_:)`.
extension GRDBAccountRepository {

  /// Streams `[Account]` snapshots whenever `account`, `instrument`,
  /// `transaction_leg`, or the joined `transaction` table changes.
  /// Initial value is the current DB state. `removeDuplicates()`
  /// coalesces re-fetches that produce the same domain value (e.g. a
  /// no-op write on an unrelated row).
  ///
  /// On observation failure the error is forwarded to the shared
  /// `errorChannel` via `surfaceAndFinish(_:)` — a single actor call
  /// that yields-then-finishes atomically, so there is no two-task race
  /// where `finish()` could run before the in-flight error is delivered.
  /// The value stream then terminates cleanly via the bridge's
  /// `continuation.finish()`.
  func observeAll() -> AsyncStream<[Account]> {
    let channel = self.errorChannel
    return
      ValueObservation
      // Region inference is empty-table-safe here: `AccountRow.fetchAll`,
      // `InstrumentRow.fetchAll`, and the `transaction_leg`/`transaction`
      // joins in `computePositions` all access columns via the row
      // decoders, so GRDB registers each table's region during the first
      // fetch even on a fresh-install profile with zero rows. Tick
      // streams that emit `Void` over `SELECT 1 FROM … LIMIT 1` (e.g.
      // `observeRates` in Stage 4) need the explicit-region form because
      // those reads never touch a column. See `DATABASE_CODE_GUIDE.md`
      // §2 convention 1 for the empty-table caveat.
      .tracking { database in
        let instruments = try Self.fetchInstrumentMap(database: database)
        let rows =
          try AccountRow
          .order(AccountRow.Columns.position.asc)
          .fetchAll(database)
        let positionsByAccount = try Self.computePositions(
          database: database, instruments: instruments)
        return try rows.map { row in
          try row.toDomain(
            instruments: instruments,
            positions: positionsByAccount[row.id] ?? [])
        }
      }
      .removeDuplicates()
      .values(in: database)
      .toAsyncStream(onError: { error in
        // Per DATABASE_CODE_GUIDE.md §2 convention 6, every observation
        // error log includes the repo + method + underlying error in the
        // exact form: "GRDB observation error in <Repo>.<method>: <error>".
        logger.error(
          "GRDB observation error in GRDBAccountRepository.observeAll: \(error.localizedDescription, privacy: .public)"
        )
        // Programmer-bug detection: SQLITE_ERROR (1) covers malformed
        // SQL, missing tables, and the schema-mismatch class. Trip an
        // assertion in debug so the bug surfaces during development;
        // release surfaces via the error channel and lets the caller
        // (typically a store) decide how to react.
        if let dbError = error as? DatabaseError, dbError.resultCode == .SQLITE_ERROR {
          assertionFailure(
            "GRDB observation programmer bug in GRDBAccountRepository.observeAll: \(error)"
          )
        }
        // TODO(#779): transient errors (SQLITE_FULL/SQLITE_IOERR) should
        // restart the observation with backoff per DATABASE_CODE_GUIDE.md
        // §2 convention 5. Currently we surface all errors and stop; the
        // restart loop lands once one of the migrated stores demonstrates
        // a real-world need —
        // https://github.com/ajsutton/moolah-native/issues/779
        await channel.surfaceAndFinish(error)
      })
  }

  /// Companion error stream — see protocol doc on `observeErrors()` and
  /// the channel's docstring for the surface-then-finish contract.
  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}
