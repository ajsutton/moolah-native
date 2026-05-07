// Backends/GRDB/Repositories/GRDBImportRuleRepository+Observation.swift

import Foundation
import GRDB

// Reactive observation surface for `ImportRuleRepository`. Split out of
// the main class file to keep `GRDBImportRuleRepository.swift` under
// SwiftLint's `file_length` warning threshold and to mirror the
// established `GRDBAccountRepository+Observation.swift` /
// `GRDBEarmarkRepository+Observation.swift` /
// `GRDBCategoryRepository+Observation.swift` companion-file pattern.
//
// `observeAll()` returns the same domain projection as `fetchAll()`:
// every `import_rule` row, ordered by `position`, mapped through
// `toDomain()`. Import rules carry no per-row joined state (no
// instrument, no positions, no transaction-leg derivation), so the
// tracking closure is a single `ImportRuleRow.fetchAll`.
//
// `observeErrors()` exposes the shared `ObservationErrorChannel.stream`
// declared on the repo instance (see `GRDBImportRuleRepository.swift`).
//
// Error handling lives entirely in `ValueObservation+RetryingAsyncStream.swift`:
// programmer bugs trip an `assertionFailure` and surface via the channel;
// transient I/O restarts the observation with backoff (1 s, 5 s, 30 s,
// capped at 5 retries); budget exhaustion surfaces the most recent
// error. See `guides/DATABASE_CODE_GUIDE.md` §2 convention 5.
extension GRDBImportRuleRepository {

  /// Streams `[ImportRule]` snapshots whenever the `import_rule` table
  /// changes. Initial value is the current DB state. `removeDuplicates()`
  /// (applied inside the retry helper) coalesces re-fetches that produce
  /// the same domain value (e.g. a no-op write on an unrelated row).
  ///
  /// `toDomain()` on `ImportRuleRow` throws `BackendError.dataCorrupted`
  /// only when `match_mode` carries a raw value the compiled `MatchMode`
  /// enum doesn't recognise — a strict invariant violation worth
  /// surfacing. JSON-decode failures on `conditions_json` /
  /// `actions_json` are absorbed inside the mapper (logged + degraded to
  /// the empty-match / no-op sentinel), matching `fetchAll()`'s
  /// behaviour, so the observation stream sees the same rows the
  /// imperative path would.
  func observeAll() -> AsyncStream<[ImportRule]> {
    ValueObservation
      // Region inference is empty-table-safe here: `ImportRuleRow.fetchAll`
      // accesses columns via the row decoder, so GRDB registers the
      // `import_rule` table's region during the first fetch even on a
      // fresh-install profile with zero rows. See
      // `GRDBAccountRepository+Observation.swift` for the identical
      // caveat applied to accounts.
      .tracking { database in
        try ImportRuleRow
          .order(ImportRuleRow.Columns.position.asc)
          .fetchAll(database)
          .map { try $0.toDomain() }
      }
      .toRetryingAsyncStream(
        in: database,
        errorChannel: errorChannel,
        repoMethod: "GRDBImportRuleRepository.observeAll")
  }

  /// Companion error stream — see protocol doc on `observeErrors()` and
  /// the channel's docstring for the surface-then-finish contract.
  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}
