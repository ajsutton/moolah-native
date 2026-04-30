// Backends/GRDB/Repositories/GRDBProfileIndexRepository.swift

import Foundation
import GRDB
import os

/// GRDB-backed repository for the app-scoped `profile` table that lives
/// in `profile-index.sqlite`. The only repository for that database; it
/// covers both the app-side mutation surface (consumed by
/// `ProfileStore`) and the sync-side dispatch surface (consumed by
/// `ProfileIndexSyncHandler`).
///
/// **Scope.** This repository is intentionally not declared on a
/// `Domain/Repositories/` protocol. The profile-index DB is an
/// app-level concern, not a per-profile data concern, so the protocol
/// boundary that Domain repositories use to keep features
/// backend-agnostic does not apply here.
///
/// **Concurrency.** `final class` + `@unchecked Sendable` rather than
/// `actor`. The CKSyncEngine delegate path calls into the repository's
/// sync entry points synchronously; converting those to `await`
/// against an `actor` would ripple async propagation through every
/// per-record-type dispatch table for no concurrency benefit (the
/// GRDB queue's serial executor already mediates concurrent access).
/// The repo's *public* mutating surface (`upsert`, `delete`,
/// `fetchAll`) is `async throws` so callers see no concurrency-model
/// change. We deliberately avoid `@MainActor` — that would propagate
/// `await` through every CKSyncEngine sync dispatch site for no
/// benefit (per Slice 3 plan §8 Q3).
///
/// **`@unchecked Sendable` justification.** `database` (`any
/// DatabaseWriter`) is itself `Sendable` (GRDB protocol guarantee —
/// the queue's serial executor mediates concurrent access). `hooks`
/// is an `OSAllocatedUnfairLock<HookState>`, which is `Sendable` and
/// guards the two `@Sendable` closures with an unfair lock so reads
/// and writes never race. `@unchecked` only waives Swift's
/// structural check that `final class` types meet `Sendable`'s
/// requirements automatically.
///
/// **Hook installation.** `ProfileContainerManager` builds the repo
/// before the `SyncCoordinator` exists (chicken-and-egg), so the repo
/// is constructed with no-op hooks and the coordinator calls
/// `attachSyncHooks(onRecordChanged:onRecordDeleted:)` once both
/// objects are available. The lock-guarded `HookState` makes the swap
/// race-free.
///
/// **Hook signature.** `(UUID) -> Void`, not the per-record-type
/// `(String, UUID)` form used by per-profile repositories. Only one
/// record type ever flows through the profile-index DB, so the
/// recordType prefix would be redundant.
final class GRDBProfileIndexRepository: @unchecked Sendable {
  /// Holds the post-init hook closures so they can be swapped in
  /// atomically by `attachSyncHooks`. A small struct rather than two
  /// independent locks so the install is a single atomic write.
  private struct HookState {
    var onRecordChanged: @Sendable (UUID) -> Void
    var onRecordDeleted: @Sendable (UUID) -> Void
  }

  private let database: any DatabaseWriter
  private let hooks: OSAllocatedUnfairLock<HookState>

  init(
    database: any DatabaseWriter,
    onRecordChanged: @escaping @Sendable (UUID) -> Void = { _ in },
    onRecordDeleted: @escaping @Sendable (UUID) -> Void = { _ in }
  ) {
    self.database = database
    self.hooks = OSAllocatedUnfairLock(
      initialState: HookState(
        onRecordChanged: onRecordChanged,
        onRecordDeleted: onRecordDeleted))
  }

  // MARK: - Wiring

  /// Replaces both hook closures atomically. Called by the
  /// `SyncCoordinator` once it exists; before that the repo is using
  /// the no-op closures from `init`.
  func attachSyncHooks(
    onRecordChanged: @escaping @Sendable (UUID) -> Void,
    onRecordDeleted: @escaping @Sendable (UUID) -> Void
  ) {
    hooks.withLock { state in
      state.onRecordChanged = onRecordChanged
      state.onRecordDeleted = onRecordDeleted
    }
  }

  // MARK: - Public async surface (consumed by ProfileStore)

  /// Returns every profile in `created_at` ascending order — the order
  /// the profile picker renders. Matches the `profile_by_created_at`
  /// index pinned by `ProfileIndexPlanPinningTests`.
  func fetchAll() async throws -> [Profile] {
    try await database.read { database in
      try ProfileRow
        .order(ProfileRow.Columns.createdAt.asc)
        .fetchAll(database)
        .map { $0.toDomain() }
    }
  }

  /// Inserts or updates a profile by id. Preserves any pre-existing
  /// `encoded_system_fields` blob — a cross-device upsert from the
  /// app-side path must not strip the CKRecord change tag, which is
  /// only ever written by the sync layer.
  func upsert(_ profile: Profile) async throws {
    try await database.write { database in
      var row = ProfileRow(domain: profile)
      // Look up the existing row (if any) and inherit its cached
      // system-fields blob. `init(domain:)` always sets
      // `encodedSystemFields = nil`, so without this copy a domain-side
      // upsert would clear the change tag on every write.
      if let existing =
        try ProfileRow
        .filter(ProfileRow.Columns.id == profile.id)
        .fetchOne(database)
      {
        row.encodedSystemFields = existing.encodedSystemFields
      }
      try row.upsert(database)
    }
    // Capture the closure under the lock, release, then invoke.
    // `OSAllocatedUnfairLock` is non-reentrant, so calling an arbitrary
    // client closure under the lock would deadlock if the closure ever
    // re-entered the repo (e.g. a future `attachSyncHooks` rotation).
    let notify = hooks.withLock { $0.onRecordChanged }
    notify(profile.id)
  }

  /// Deletes a single profile by id. Returns `true` when a row was
  /// removed; `false` when no row existed (idempotent — sign-out and
  /// zone-delete callers don't need to track existence themselves).
  /// Hook fires only when a row was actually deleted.
  @discardableResult
  func delete(id: UUID) async throws -> Bool {
    let didDelete = try await database.write { database in
      try ProfileRow.deleteOne(database, id: id)
    }
    if didDelete {
      // See `upsert` for the lock-then-invoke rationale.
      let notify = hooks.withLock { $0.onRecordDeleted }
      notify(id)
    }
    return didDelete
  }

  // MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
  //
  // Called from `ProfileIndexSyncHandler` static dispatch tables on the
  // CKSyncEngine delegate's executor. `DatabaseWriter.write { db in … }`
  // has both async and sync overloads; the sync form blocks the calling
  // thread until the queue's serial executor admits the closure. Used
  // only off-MainActor; never call these synchronously from MainActor.

  /// Applies a CKSyncEngine remote-change batch in one transaction:
  /// every saved row is upserted and every deleted id is removed
  /// inside a single `database.write`. If any statement throws, the
  /// whole batch rolls back so prior on-disk state survives byte-equal
  /// — required by the rollback contract in
  /// `guides/DATABASE_CODE_GUIDE.md`.
  func applyRemoteChangesSync(saved rows: [ProfileRow], deleted ids: [UUID]) throws {
    try database.write { database in
      for row in rows {
        // `upsert` matches on the PK conflict (`id`). Because
        // `recordName(for: id)` is total over `id`, the implied UNIQUE
        // conflict on `record_name` is satisfied by the same row, so a
        // single conflict target suffices.
        try row.upsert(database)
      }
      for id in ids {
        _ = try ProfileRow.deleteOne(database, id: id)
      }
    }
  }

  /// Writes (or clears) the cached system-fields blob on a single row.
  /// Returns `true` when a row was found and updated.
  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try ProfileRow
        .filter(ProfileRow.Columns.id == id)
        .updateAll(database, [ProfileRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  /// Clears `encoded_system_fields` on every row. Used after an
  /// `encryptedDataReset`.
  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try ProfileRow
        .updateAll(
          database,
          [ProfileRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  /// Looks up a single row by id. Used by the per-record upload path.
  func fetchRowSync(id: UUID) throws -> ProfileRow? {
    try database.read { database in
      try ProfileRow
        .filter(ProfileRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  /// Returns IDs of every row in the table. Used by
  /// `queueAllExistingRecords()` to seed the sync engine.
  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try ProfileRow
        .select(ProfileRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Deletes every row in the table. Used on zone delete / sign-out.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try ProfileRow.deleteAll(database)
    }
  }
}
