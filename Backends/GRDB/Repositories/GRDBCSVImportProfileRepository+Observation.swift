// Backends/GRDB/Repositories/GRDBCSVImportProfileRepository+Observation.swift

import Foundation
import GRDB

// Reactive observation surface for `CSVImportProfileRepository`. Split
// out of the main class file to keep `GRDBCSVImportProfileRepository.swift`
// under SwiftLint's `file_length` warning threshold and to mirror the
// established `GRDBImportRuleRepository+Observation.swift` /
// `GRDBCategoryRepository+Observation.swift` companion-file pattern.
//
// `observeAll()` returns the same domain projection as `fetchAll()`:
// every `csv_import_profile` row, ordered by `created_at`, mapped
// through `toDomain()`. CSV import profiles carry no per-row joined
// state (no instrument, no positions, no transaction-leg derivation),
// so the tracking closure is a single `CSVImportProfileRow.fetchAll`.
//
// `observeErrors()` exposes the shared `ObservationErrorChannel.stream`
// declared on the repo instance (see `GRDBCSVImportProfileRepository.swift`).
//
// Error handling lives entirely in `ValueObservation+RetryingAsyncStream.swift`:
// programmer bugs trip an `assertionFailure` and surface via the channel;
// transient I/O restarts the observation with backoff (1 s, 5 s, 30 s,
// capped at 5 retries); budget exhaustion surfaces the most recent
// error. See `guides/DATABASE_CODE_GUIDE.md` §2 convention 5.
extension GRDBCSVImportProfileRepository {

  /// Streams `[CSVImportProfile]` snapshots whenever the
  /// `csv_import_profile` table changes. Initial value is the current
  /// DB state. `removeDuplicates()` (applied inside the retry helper)
  /// coalesces re-fetches that produce the same domain value (e.g. a
  /// no-op write on an unrelated row).
  func observeAll() -> AsyncStream<[CSVImportProfile]> {
    ValueObservation
      // Explicit-region form via `CSVImportProfileRow.observableRegion`
      // so the sync-bookkeeping `encoded_system_fields` writes that
      // land after every successful CKSyncEngine send do not re-fire
      // this observation. See issue #865 and
      // `Records/AccountRow+ObservableRegion.swift`. The region is
      // pre-declared, so it is also empty-table-safe on a fresh-install
      // profile.
      .tracking(
        regions: [CSVImportProfileRow.observableRegion],
        fetch: { database in
          try CSVImportProfileRow
            .order(CSVImportProfileRow.Columns.createdAt.asc)
            .fetchAll(database)
            .map { $0.toDomain() }
        }
      )
      .toRetryingAsyncStream(
        in: database,
        errorChannel: errorChannel,
        repoMethod: "GRDBCSVImportProfileRepository.observeAll")
  }

  /// Companion error stream — see protocol doc on `observeErrors()` and
  /// the channel's docstring for the surface-then-finish contract.
  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}
