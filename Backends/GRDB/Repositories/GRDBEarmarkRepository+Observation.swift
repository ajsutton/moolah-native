// Backends/GRDB/Repositories/GRDBEarmarkRepository+Observation.swift

import Foundation
import GRDB

// Reactive observation surface for `EarmarkRepository`. Split out of the
// main class file to keep `GRDBEarmarkRepository.swift` under SwiftLint's
// `file_length` warning threshold and to mirror the established
// `+Positions.swift` companion-file pattern.
//
// `observeAll()` returns the same domain projection as `fetchAll()`:
// earmark rows ordered by `position`, each populated with their full
// instrument plus per-instrument `Position` lists computed from
// non-scheduled `transaction_leg` rows.
//
// `observeBudget(earmarkId:)` returns the same projection as
// `fetchBudget(earmarkId:)`: the budget items for a single earmark,
// labelled with the earmark's instrument.
//
// `observeErrors()` exposes the shared `ObservationErrorChannel.stream`
// declared on the repo instance (see `GRDBEarmarkRepository.swift`).
//
// Error handling lives entirely in `ValueObservation+RetryingAsyncStream.swift`:
// programmer bugs trip an `assertionFailure` and surface via the channel;
// transient I/O restarts the observation with backoff (1 s, 5 s, 30 s,
// capped at 5 retries); budget exhaustion surfaces the most recent
// error. See `guides/DATABASE_CODE_GUIDE.md` §2 convention 5.
extension GRDBEarmarkRepository {

  /// Streams `[Earmark]` snapshots whenever `earmark`, `instrument`,
  /// `transaction_leg`, or the joined `transaction` table changes.
  /// Initial value is the current DB state. `removeDuplicates()` (applied
  /// inside the retry helper) coalesces re-fetches that produce the same
  /// domain value (e.g. a no-op write on an unrelated row).
  func observeAll() -> AsyncStream<[Earmark]> {
    let defaultInstrument = self.defaultInstrument
    return
      ValueObservation
      // Region inference is empty-table-safe here: `EarmarkRow.fetchAll`,
      // `InstrumentRow.fetchAll`, and the `transaction_leg` /
      // `transaction` joins inside `computeEarmarkPositions` all access
      // columns via the row decoders, so GRDB registers each table's
      // region during the first fetch even on a fresh-install profile
      // with zero rows. See `GRDBAccountRepository+Observation.swift`
      // for the identical caveat applied to accounts.
      //
      // Projection parity with `fetchAll()`: instruments + ordered rows +
      // computed positions, mapped to `Earmark` via `row.toDomain`.
      .tracking { database in
        let instruments = try Self.fetchInstrumentMap(database: database)
        let positionsByEarmark = try Self.computeEarmarkPositions(
          database: database, instruments: instruments)
        let rows =
          try EarmarkRow
          .order(EarmarkRow.Columns.position.asc)
          .fetchAll(database)
        return rows.map { row in
          let lists = positionsByEarmark[row.id] ?? EarmarkPositionLists.empty
          return row.toDomain(
            defaultInstrument: defaultInstrument,
            positions: lists.positions,
            savedPositions: lists.savedPositions,
            spentPositions: lists.spentPositions)
        }
      }
      .toRetryingAsyncStream(
        in: database,
        errorChannel: errorChannel,
        repoMethod: "GRDBEarmarkRepository.observeAll")
  }

  /// Streams `[EarmarkBudgetItem]` snapshots for a single earmark.
  /// Captures `earmarkId` into the tracking closure so re-fetches on
  /// later table changes still scope the read by id. Tracks both
  /// `earmark_budget_item` (the rows being selected) and `earmark`
  /// (whose `instrument_id` labels the result), so an instrument flip
  /// on the parent earmark re-emits the budget with the new label.
  func observeBudget(earmarkId: UUID) -> AsyncStream<[EarmarkBudgetItem]> {
    let defaultInstrument = self.defaultInstrument
    return
      ValueObservation
      .tracking { database in
        // Resolve the earmark's instrument first so budget items inherit
        // the same instrument label — mirrors `fetchBudget(earmarkId:)`.
        let earmarkInstrument: Instrument
        if let earmarkRow =
          try EarmarkRow
          .filter(EarmarkRow.Columns.id == earmarkId)
          .fetchOne(database)
        {
          earmarkInstrument =
            earmarkRow.instrumentId.map { Instrument.fiat(code: $0) }
            ?? defaultInstrument
        } else {
          earmarkInstrument = defaultInstrument
        }

        let rows =
          try EarmarkBudgetItemRow
          .filter(EarmarkBudgetItemRow.Columns.earmarkId == earmarkId)
          .fetchAll(database)
        return rows.map { $0.toDomain(earmarkInstrument: earmarkInstrument) }
      }
      .toRetryingAsyncStream(
        in: database,
        errorChannel: errorChannel,
        repoMethod: "GRDBEarmarkRepository.observeBudget")
  }

  /// Companion error stream — see protocol doc on `observeErrors()` and
  /// the channel's docstring for the surface-then-finish contract.
  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}
