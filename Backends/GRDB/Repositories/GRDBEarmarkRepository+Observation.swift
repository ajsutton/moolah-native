// Backends/GRDB/Repositories/GRDBEarmarkRepository+Observation.swift

import Foundation
import GRDB

// Reactive observation surface for `EarmarkRepository`.
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
//
// **Instrument-map snapshot.** The canonical instrument registry lives
// on a separate (profile-index) database, so its lookup table cannot be
// joined into the per-profile `ValueObservation` (the synchronous
// `tracking(regions:fetch:)` closure cannot `await`). `observeAll()`
// resolves the map once via `instrumentResolver` when the stream's
// worker task starts, captures it into the tracking closure, and drops
// `InstrumentRow.observableRegion` from the tracked regions (those rows
// live on the separate profile-index DB). An instrument-metadata edit
// therefore does not live-refresh an already-open list until the next refetch
// (re-subscribe). `observeBudget(earmarkId:)` does not consult the
// instrument map (it labels items from the parent earmark's own
// `instrument_id`), so it keeps the plain synchronous shape. The
// async-resolve-then-observe bridge is `resolvedInstrumentMapStream`
// (see `Backends/GRDB/Observation/InstrumentMapObservationBridge.swift`).
extension GRDBEarmarkRepository {

  /// Streams `[Earmark]` snapshots whenever `earmark`,
  /// `transaction_leg`, or the joined `transaction` table changes.
  /// Initial value is the current DB state. Instrument identity is
  /// resolved once at subscription start via `instrumentResolver` and
  /// captured into the stream; an instrument-metadata change does not
  /// re-fire this observation until the subscription is cancelled and
  /// restarted. `removeDuplicates()` (applied inside the retry helper)
  /// coalesces re-fetches that produce the same domain value (e.g. a
  /// no-op write on an unrelated row).
  func observeAll() -> AsyncStream<[Earmark]> {
    let defaultInstrument = self.defaultInstrument
    return resolvedInstrumentMapStream(
      resolver: instrumentResolver,
      errorChannel: errorChannel,
      database: database
    ) { instruments, errorChannel, database in
      ValueObservation
        // Explicit-region form: every joined table's `observableRegion`
        // excludes the sync-bookkeeping `encoded_system_fields` blob, so
        // CKSyncEngine's per-batch system-fields write does not re-fire
        // this observation. See issue #865. `InstrumentRow` is not
        // tracked here — those rows live on the separate profile-index
        // database; the map is the captured `instruments` snapshot.
        //
        // Projection parity with `fetchAll()`: instruments + ordered
        // rows + computed positions, mapped to `Earmark` via
        // `row.toDomain`.
        .tracking(
          regions: [
            EarmarkRow.observableRegion,
            TransactionRow.observableRegion,
            TransactionLegRow.observableRegion,
          ],
          fetch: { database in
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
        )
        .toRetryingAsyncStream(
          in: database,
          errorChannel: errorChannel,
          repoMethod: "GRDBEarmarkRepository.observeAll")
    }
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
      // Explicit-region form so the sync-bookkeeping
      // `encoded_system_fields` writes on `earmark` and
      // `earmark_budget_item` do not re-fire this observation. See
      // issue #865.
      .tracking(
        regions: [
          EarmarkRow.observableRegion,
          EarmarkBudgetItemRow.observableRegion,
        ],
        fetch: { [earmarkId, defaultInstrument] database in
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
      )
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
