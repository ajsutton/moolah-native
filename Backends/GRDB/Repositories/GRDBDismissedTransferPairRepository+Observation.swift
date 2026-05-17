// Backends/GRDB/Repositories/GRDBDismissedTransferPairRepository+Observation.swift

import Foundation
import GRDB

// Reactive observation surface for `DismissedTransferPairRepository`.
//
// `observeAll()` returns the same domain projection as `fetchAll()`:
// every `dismissed_transfer_pair` row, ordered by `dismissed_at`, mapped
// through `toDomain()`. Dismissed pairs carry no per-row joined state,
// so the tracking closure is a single `DismissedTransferPairRow.fetchAll`.
//
// `observeErrors()` exposes the shared `ObservationErrorChannel.stream`
// declared on the repo instance (see
// `GRDBDismissedTransferPairRepository.swift`).
//
// Error handling lives entirely in `ValueObservation+RetryingAsyncStream.swift`:
// programmer bugs trip an `assertionFailure` and surface via the channel;
// transient I/O restarts the observation with backoff (1 s, 5 s, 30 s,
// capped at 5 retries); budget exhaustion surfaces the most recent
// error. See `guides/DATABASE_CODE_GUIDE.md` §2 convention 5.
extension GRDBDismissedTransferPairRepository {

  /// Streams `[DismissedTransferPair]` snapshots whenever the
  /// `dismissed_transfer_pair` table changes. Initial value is the
  /// current DB state. `removeDuplicates()` (applied inside the retry
  /// helper) coalesces re-fetches that produce the same domain value
  /// (e.g. a no-op write on an unrelated row).
  func observeAll() -> AsyncStream<[DismissedTransferPair]> {
    ValueObservation
      // Explicit-region form via
      // `DismissedTransferPairRow.observableRegion` so the
      // sync-bookkeeping `encoded_system_fields` writes that land after
      // every successful CKSyncEngine send do not re-fire this
      // observation. See issue #865 and
      // `Records/AccountRow+ObservableRegion.swift`. The region is
      // pre-declared, so it is also empty-table-safe on a fresh-install
      // profile — no need for the row-decoder workaround the inferred
      // form depended on.
      .tracking(
        regions: [DismissedTransferPairRow.observableRegion],
        fetch: { database in
          try DismissedTransferPairRow
            .order(DismissedTransferPairRow.Columns.dismissedAt.asc)
            .fetchAll(database)
            .map { $0.toDomain() }
        }
      )
      .toRetryingAsyncStream(
        in: database,
        errorChannel: errorChannel,
        repoMethod: "GRDBDismissedTransferPairRepository.observeAll")
  }

  /// Companion error stream — see protocol doc on `observeErrors()` and
  /// the channel's docstring for the surface-then-finish contract.
  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}
