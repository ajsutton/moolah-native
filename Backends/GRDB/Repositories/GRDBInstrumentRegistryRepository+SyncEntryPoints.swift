// Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+SyncEntryPoints.swift

import Foundation
import GRDB

/// Synchronous entry points consumed by `ProfileIndexSyncHandler` and
/// the coordinator's startup self-heal scan.
///
/// These methods are called from the CKSyncEngine delegate executor
/// on a non-MainActor context. `DatabaseWriter.write { db in … }` has
/// both async and sync overloads; the sync form blocks the calling
/// thread until the queue's serial executor admits the closure. Never
/// call any of these from `@MainActor`.
extension GRDBInstrumentRegistryRepository {

  /// Writes (or clears) the cached system-fields blob on a single row.
  /// Returns `true` when a row was found and updated.
  @discardableResult
  func setEncodedSystemFieldsSync(id: String, data: Data?) throws -> Bool {
    let updated = try database.write { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.id == id)
        .updateAll(database, [InstrumentRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
    // System-fields-only writes don't change the domain `Instrument`,
    // but a blanket invalidate-on-any-write keeps the staleness
    // invariant simple and provably correct — the cost is one extra
    // rebuild, never stale data.
    invalidateInstrumentMapCache()
    return updated
  }

  /// Clears `encoded_system_fields` on every row. Used after an
  /// `encryptedDataReset`.
  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try InstrumentRow
        .updateAll(
          database,
          [InstrumentRow.Columns.encodedSystemFields.set(to: nil)])
    }
    invalidateInstrumentMapCache()
  }

  /// Returns IDs of rows whose `encoded_system_fields` is `NULL`.
  func unsyncedRowIdsSync() throws -> [String] {
    try database.read { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.encodedSystemFields == nil)
        .select(InstrumentRow.Columns.id, as: String.self)
        .fetchAll(database)
    }
  }

  /// Returns IDs of every row in the table.
  func allRowIdsSync() throws -> [String] {
    try database.read { database in
      try InstrumentRow
        .select(InstrumentRow.Columns.id, as: String.self)
        .fetchAll(database)
    }
  }

  /// Looks up a single row by id. Used by the per-record upload path
  /// in the sync handler.
  func fetchRowSync(id: String) throws -> InstrumentRow? {
    try database.read { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  /// Batch lookup by ids — used by the batch-build phase of the sync
  /// handler.
  func fetchRowsSync(ids: [String]) throws -> [InstrumentRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try InstrumentRow
        .filter(idSet.contains(InstrumentRow.Columns.id))
        .fetchAll(database)
    }
  }

  /// Deletes every row in the table. Used by `deleteLocalData` after
  /// a remote zone deletion.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try InstrumentRow.deleteAll(database)
    }
    invalidateInstrumentMapCache()
  }
}
