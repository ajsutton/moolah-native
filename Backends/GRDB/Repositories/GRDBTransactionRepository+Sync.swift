// Backends/GRDB/Repositories/GRDBTransactionRepository+Sync.swift

import Foundation
import GRDB

// MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
//
// Called from the CKSyncEngine delegate executor on a non-MainActor
// context. `DatabaseWriter.write { db in … }` has both async and sync
// overloads; the sync form blocks the calling thread until the queue's
// serial executor admits the closure. Never call these from
// `@MainActor`.

extension GRDBTransactionRepository {
  func applyRemoteChangesSync(saved rows: [TransactionRow], deleted ids: [UUID]) throws {
    try database.write { database in
      try applyRemoteChangesSync(saved: rows, deleted: ids, in: database)
    }
  }

  /// In-transaction variant — see `GRDBCSVImportProfileRepository.applyRemoteChangesSync(...:in:)`
  /// for the rationale (one commit per `applyRemoteChanges` batch, issue #872).
  func applyRemoteChangesSync(
    saved rows: [TransactionRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows {
      try row.upsert(database)
    }
    for id in ids {
      _ =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.transactionId == id)
        .deleteAll(database)
      _ = try TransactionRow.deleteOne(database, id: id)
    }
  }

  /// Writes (or clears) the cached system-fields blob on a single row.
  /// Returns `true` when a row was found and updated.
  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try TransactionRow
        .filter(TransactionRow.Columns.id == id)
        .updateAll(
          database,
          [TransactionRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  /// Writes (or clears) the cached system-fields blob across many rows
  /// in a single GRDB transaction so `databaseDidCommit` fires once,
  /// not once per row. Used by the post-`sendChanges` write-back path
  /// in `ProfileDataSyncHandler.updateSystemFieldsForSaved` to avoid
  /// re-firing every UI `ValueObservation` (and the `TransactionStore`
  /// reload + per-row currency conversion they retrigger) for every
  /// successfully-uploaded row in a batch. Returns the number of rows
  /// updated. The empty-input fast path skips the transaction entirely.
  /// See issue #865 for the follow-up that narrows the observation
  /// region so the column itself doesn't trigger UI re-fetches.
  func setEncodedSystemFieldsBatchSync(
    _ updates: [(id: UUID, data: Data?)]
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
    return try database.write { database in
      var updatedCount = 0
      for (id, data) in updates {
        updatedCount +=
          try TransactionRow
          .filter(TransactionRow.Columns.id == id)
          .updateAll(
            database,
            [TransactionRow.Columns.encodedSystemFields.set(to: data)])
      }
      return updatedCount
    }
  }

  /// Clears `encoded_system_fields` on every row. Used after an
  /// `encryptedDataReset`.
  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try TransactionRow
        .updateAll(
          database,
          [TransactionRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  /// Returns IDs of rows whose `encoded_system_fields` is `NULL`.
  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try TransactionRow
        .filter(TransactionRow.Columns.encodedSystemFields == nil)
        .select(TransactionRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Returns IDs of every row in the table.
  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try TransactionRow
        .select(TransactionRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Looks up a single row by id. Used by the per-record upload path
  /// in the sync handler.
  func fetchRowSync(id: UUID) throws -> TransactionRow? {
    try database.read { database in
      try TransactionRow
        .filter(TransactionRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  /// Batch lookup by ids — used by the batch-build phase of the sync
  /// handler.
  func fetchRowsSync(ids: [UUID]) throws -> [TransactionRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try TransactionRow
        .filter(idSet.contains(TransactionRow.Columns.id))
        .fetchAll(database)
    }
  }

  /// Deletes every row in the table. Used by `deleteLocalData` after a
  /// remote zone deletion.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try TransactionRow.deleteAll(database)
    }
  }
}
