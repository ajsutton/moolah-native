// Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+SyncHooks.swift

import Foundation
import os

/// Sync-hook plumbing for `GRDBInstrumentRegistryRepository`.
///
/// The shared instrument registry is constructed at app boot before
/// `SyncCoordinator` exists; the coordinator rotates real hooks in
/// via `attachSyncHooks` once both objects are available. Mirrors
/// the lock-guarded `HookState` shape used by
/// `GRDBProfileIndexRepository`.
extension GRDBInstrumentRegistryRepository {
  /// Lock-guarded state behind the memoised instrument-map snapshot.
  ///
  /// `isValid == false` means "needs rebuild" (an empty `snapshot` is a
  /// legitimate cached value, so a separate validity flag rather than an
  /// optional-collection sentinel expresses the state). `generation` is
  /// bumped by every invalidation; `instrumentMap()` reads the
  /// generation before its `await database.read`, then only commits the
  /// rebuilt snapshot if the generation is unchanged — so a mutation
  /// that lands *during* the async read is never lost (it would
  /// otherwise leave a stale-but-`isValid` snapshot). `dbReadCount`
  /// counts only the branches that actually re-read the database.
  struct MapCacheState {
    var snapshot: [String: Instrument]
    var isValid: Bool
    var generation: Int
    var dbReadCount: Int
  }

  /// Replaces both hook closures atomically. Called by the
  /// `SyncCoordinator` once it exists; before that the repo is using
  /// the no-op closures from `init`.
  func attachSyncHooks(
    onRecordChanged: @escaping @Sendable (String) -> Void,
    onRecordDeleted: @escaping @Sendable (String) -> Void
  ) {
    hooks.withLock { state in
      state.onRecordChanged = onRecordChanged
      state.onRecordDeleted = onRecordDeleted
    }
  }

  /// Captures `onRecordChanged` under the lock, releases the lock,
  /// then invokes the captured closure. Non-reentrant lock semantics
  /// mean the client closure must never re-enter the repo while the
  /// lock is held, so the read-then-call pattern is required.
  func fireOnRecordChanged(_ id: String) {
    let notify = hooks.withLock { $0.onRecordChanged }
    notify(id)
  }

  /// Captures `onRecordDeleted` under the lock, releases the lock,
  /// then invokes the captured closure. Same non-reentrancy rationale
  /// as `fireOnRecordChanged`.
  func fireOnRecordDeleted(_ id: String) {
    let notify = hooks.withLock { $0.onRecordDeleted }
    notify(id)
  }

  /// Drops the memoised instrument-map snapshot so the next
  /// `instrumentMap()` call rebuilds it from the database. Called from
  /// every mutation path — local writes, the `*Sync` entry points, and
  /// the remote-apply path — at the point the row write has succeeded,
  /// so a reader after a mutation can never observe stale data. A
  /// blanket invalidate-on-any-write (even for metadata-only writes
  /// like `setEncodedSystemFieldsSync`) keeps the invariant simple and
  /// correct; the cost is one extra rebuild, not staleness.
  func invalidateInstrumentMapCache() {
    mapCache.withLock { state in
      state.isValid = false
      state.generation &+= 1
    }
  }

  /// Number of times `instrumentMap()` actually re-read the database to
  /// rebuild the memoised snapshot. Test-only accessor — kept with the
  /// `ForTesting` suffix per `guides/DATABASE_CODE_GUIDE.md` §7 so the
  /// production API surface stays clean. Exposed for the
  /// cache-invariant tests in `GRDBInstrumentMapCacheTests` so they can
  /// assert that repeated reads collapse to a single rebuild and that
  /// every mutation path forces exactly one further rebuild.
  ///
  /// Under concurrent callers racing the cold path, every in-flight
  /// `database.read` increments this counter, so it counts actual DB
  /// rebuilds (which may exceed 1 per logical cache-miss when several
  /// readers race a single invalidation) — it is a rebuild-storm canary,
  /// not a strict logical-miss count.
  var instrumentMapDBReadCountForTesting: Int {
    mapCache.withLock { $0.dbReadCount }
  }
}
