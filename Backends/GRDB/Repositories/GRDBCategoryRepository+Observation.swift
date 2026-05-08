// Backends/GRDB/Repositories/GRDBCategoryRepository+Observation.swift

import Foundation
import GRDB

// Reactive observation surface for `CategoryRepository`. Split out of
// the main class file to keep `GRDBCategoryRepository.swift` under
// SwiftLint's `file_length` warning threshold and to mirror the
// established `GRDBAccountRepository+Observation.swift` /
// `GRDBEarmarkRepository+Observation.swift` companion-file pattern.
//
// `observeAll()` returns the same domain projection as `fetchAll()`:
// every `category` row, ordered by `name`, mapped through `toDomain()`.
// Categories carry no per-row joined state (no instrument, no positions,
// no transaction-leg derivation), so the tracking closure is a single
// `CategoryRow.fetchAll`.
//
// `observeErrors()` exposes the shared `ObservationErrorChannel.stream`
// declared on the repo instance (see `GRDBCategoryRepository.swift`).
//
// Error handling lives entirely in `ValueObservation+RetryingAsyncStream.swift`:
// programmer bugs trip an `assertionFailure` and surface via the channel;
// transient I/O restarts the observation with backoff (1 s, 5 s, 30 s,
// capped at 5 retries); budget exhaustion surfaces the most recent
// error. See `guides/DATABASE_CODE_GUIDE.md` §2 convention 5.
extension GRDBCategoryRepository {

  /// Streams `[Category]` snapshots whenever the `category` table
  /// changes. Initial value is the current DB state. `removeDuplicates()`
  /// (applied inside the retry helper) coalesces re-fetches that produce
  /// the same domain value (e.g. a no-op write on an unrelated row).
  func observeAll() -> AsyncStream<[Moolah.Category]> {
    ValueObservation
      // Region inference is empty-table-safe here: `CategoryRow.fetchAll`
      // accesses columns via the row decoder, so GRDB registers the
      // `category` table's region during the first fetch even on a
      // fresh-install profile with zero rows. See
      // `GRDBAccountRepository+Observation.swift` for the identical
      // caveat applied to accounts.
      .tracking { database in
        try CategoryRow
          .order(CategoryRow.Columns.name.asc)
          .fetchAll(database)
          .map { $0.toDomain() }
      }
      .toRetryingAsyncStream(
        in: database,
        errorChannel: errorChannel,
        repoMethod: "GRDBCategoryRepository.observeAll")
  }

  /// Companion error stream — see protocol doc on `observeErrors()` and
  /// the channel's docstring for the surface-then-finish contract.
  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}
