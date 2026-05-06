// Backends/GRDB/Repositories/GRDBAccountRepository+Observation.swift

import Foundation
import GRDB

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
//
// Error handling lives entirely in `ValueObservation+RetryingAsyncStream.swift`:
// programmer bugs trip an `assertionFailure` and surface via the channel;
// transient I/O restarts the observation with backoff (1 s, 5 s, 30 s,
// capped at 5 retries); budget exhaustion surfaces the most recent
// error. See `guides/DATABASE_CODE_GUIDE.md` §2 convention 5.
extension GRDBAccountRepository {

  /// Streams `[Account]` snapshots whenever `account`, `instrument`,
  /// `transaction_leg`, or the joined `transaction` table changes.
  /// Initial value is the current DB state. `removeDuplicates()` (applied
  /// inside the retry helper) coalesces re-fetches that produce the same
  /// domain value (e.g. a no-op write on an unrelated row).
  func observeAll() -> AsyncStream<[Account]> {
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
      //
      // Projection parity with `fetchAll()`: instruments + ordered rows +
      // computed positions, mapped to `Account` via `row.toDomain`.
      // The retry helper re-runs this closure on each restart attempt,
      // so the projection always reads the freshest DB state.
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
      .toRetryingAsyncStream(
        in: database,
        errorChannel: errorChannel,
        repoMethod: "GRDBAccountRepository.observeAll")
  }

  /// Companion error stream — see protocol doc on `observeErrors()` and
  /// the channel's docstring for the surface-then-finish contract.
  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}
