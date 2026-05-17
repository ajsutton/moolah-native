// Backends/GRDB/Repositories/GRDBDismissedTransferPairRepository.swift

import Foundation
import GRDB

/// GRDB-backed implementation of `DismissedTransferPairRepository` over
/// the `dismissed_transfer_pair` table.
///
/// `create` upserts on the content-addressed primary key: the domain
/// `DismissedTransferPair.id` is a deterministic UUID of the unordered
/// transaction-id pair, so re-dismissing the same pair on any device —
/// in any argument order — writes the same row (idempotent
/// cross-device convergence).
///
/// **`@unchecked Sendable` justification.** All stored properties are
/// `let`. `database` (`any DatabaseWriter`) is itself `Sendable` (GRDB
/// protocol guarantee — the queue's serial executor mediates concurrent
/// access). `onRecordChanged` and `onRecordDeleted` are `@Sendable`
/// closures captured at init. Nothing mutates post-init, so the
/// reference can be shared across actor boundaries without a data
/// race; `@unchecked` only waives Swift's structural check that
/// `final class` types meet `Sendable`'s requirements automatically.
/// See `guides/CONCURRENCY_GUIDE.md` §2 "False Positives to Avoid",
/// Carve-out 3 (GRDB repositories).
final class GRDBDismissedTransferPairRepository: DismissedTransferPairRepository,
  @unchecked Sendable
{
  // `database` and `errorChannel` are deliberately not `private` so the
  // sibling `+Observation.swift` extension can reach them. Treat them
  // as private-by-convention from elsewhere in the module.
  let database: any DatabaseWriter
  private let onRecordChanged: @Sendable (String, UUID) -> Void
  private let onRecordDeleted: @Sendable (String, UUID) -> Void
  /// Single shared error channel for every `observeAll()` subscription
  /// returned by this repo instance. The bridge in
  /// `Backends/GRDB/Observation/AsyncValueObservation+AsyncStream.swift`
  /// is single-shot, so once `surfaceAndFinish(_:)` is called the
  /// channel terminates — subsequent observations from the same repo
  /// share that fate. Matches `GRDBCategoryRepository.errorChannel`.
  let errorChannel = ObservationErrorChannel()

  init(
    database: any DatabaseWriter,
    onRecordChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onRecordDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in }
  ) {
    self.database = database
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
  }

  // MARK: - DismissedTransferPairRepository conformance

  func fetchAll() async throws -> [DismissedTransferPair] {
    try await database.read { database in
      try DismissedTransferPairRow
        .order(DismissedTransferPairRow.Columns.dismissedAt.asc)
        .fetchAll(database)
        .map { $0.toDomain() }
    }
  }

  func create(_ pair: DismissedTransferPair) async throws -> DismissedTransferPair {
    let row = DismissedTransferPairRow(domain: pair)
    try await database.write { database in
      // Content-addressed PK: an identical re-dismissal (any device,
      // any argument order) upserts the same row rather than failing on
      // a duplicate-key constraint.
      try row.upsert(database)
    }
    onRecordChanged(DismissedTransferPairRow.recordType, pair.id)
    return row.toDomain()
  }

  func delete(id: UUID) async throws {
    try await database.write { database in
      _ = try DismissedTransferPairRow.deleteOne(database, id: id)
    }
    onRecordDeleted(DismissedTransferPairRow.recordType, id)
  }

  func pairs(touching transactionId: UUID) async throws -> [DismissedTransferPair] {
    try await database.read { database in
      try DismissedTransferPairRow
        .filter(
          DismissedTransferPairRow.Columns.transactionIdA == transactionId
            || DismissedTransferPairRow.Columns.transactionIdB == transactionId
        )
        .fetchAll(database)
        .map { $0.toDomain() }
    }
  }

  // MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
  //
  // Called from the CKSyncEngine delegate executor on a non-MainActor
  // context. `DatabaseWriter.write { db in … }` has both async and sync
  // overloads; the sync form blocks the calling thread until the queue's
  // serial executor admits the closure. Never call these from
  // `@MainActor`.

  func applyRemoteChangesSync(saved rows: [DismissedTransferPairRow], deleted ids: [UUID]) throws {
    try database.write { database in
      try applyRemoteChangesSync(saved: rows, deleted: ids, in: database)
    }
  }

  /// In-transaction variant — see
  /// `GRDBCSVImportProfileRepository.applyRemoteChangesSync(...:in:)`
  /// for the rationale (one commit per `applyRemoteChanges` batch, issue #872).
  func applyRemoteChangesSync(
    saved rows: [DismissedTransferPairRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows {
      try row.upsert(database)
    }
    for id in ids {
      _ = try DismissedTransferPairRow.deleteOne(database, id: id)
    }
  }

  /// Writes (or clears) the cached system-fields blob on a single row.
  /// Returns `true` when a row was found and updated.
  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try DismissedTransferPairRow
        .filter(DismissedTransferPairRow.Columns.id == id)
        .updateAll(
          database, [DismissedTransferPairRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  /// Clears `encoded_system_fields` on every row. Used after an
  /// `encryptedDataReset`.
  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try DismissedTransferPairRow
        .updateAll(
          database,
          [DismissedTransferPairRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  /// Returns IDs of rows whose `encoded_system_fields` is `NULL`.
  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try DismissedTransferPairRow
        .filter(DismissedTransferPairRow.Columns.encodedSystemFields == nil)
        .select(DismissedTransferPairRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Returns IDs of every row in the table.
  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try DismissedTransferPairRow
        .select(DismissedTransferPairRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Looks up a single row by id. Used by the per-record upload path in
  /// the sync handler.
  func fetchRowSync(id: UUID) throws -> DismissedTransferPairRow? {
    try database.read { database in
      try DismissedTransferPairRow
        .filter(DismissedTransferPairRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  /// Batch lookup by ids — used by the batch-build phase of the sync
  /// handler.
  func fetchRowsSync(ids: [UUID]) throws -> [DismissedTransferPairRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try DismissedTransferPairRow
        .filter(idSet.contains(DismissedTransferPairRow.Columns.id))
        .fetchAll(database)
    }
  }

  /// Deletes every row in the table. Used by `deleteLocalData` after a
  /// remote zone deletion.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try DismissedTransferPairRow.deleteAll(database)
    }
  }
}
