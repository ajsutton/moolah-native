// Backends/GRDB/Repositories/GRDBCSVImportProfileRepository.swift

import Foundation
import GRDB

/// GRDB-backed implementation of `CSVImportProfileRepository`. Replaces
/// the SwiftData-backed `CloudKitCSVImportProfileRepository` for the
/// `csv_import_profile` table introduced by `v2_csv_import_and_rules`.
///
/// **Concurrency.** `final class` + `@unchecked Sendable` rather than
/// `actor`, mirroring the existing CloudKit-repo shape. Plan
/// `plans/grdb-slice-0-csv-import.md` §3.7 originally recommended `actor`
/// but flagged the fallback: "If `actor` introduces an `await` cascade
/// that `@unchecked Sendable` avoided, fall back to the existing
/// pattern." The cascade does materialise here — `ProfileDataSyncHandler`
/// sync entry points (`applyBatchSaves`, `recordToSave`,
/// `setEncodedSystemFields`, etc.) are synchronous and called from
/// CKSyncEngine delegate paths that are not trivially convertible to
/// `async` without rippling through every record-type's dispatch table.
/// Sticking with the class shape keeps slice 0's blast radius tight; the
/// repo's *public* protocol surface is still `async throws` (writes go
/// through the GRDB queue's serialised executor; reads do too) so callers
/// see no concurrency-model change. Hook closures are `let` properties
/// set during `init` per the plan — post-init reassignment is not
/// supported.
///
/// **`@unchecked Sendable` justification.** All stored properties are
/// `let`. `database` (`any DatabaseWriter`) is itself `Sendable` (GRDB
/// protocol guarantee — the queue's serial executor mediates concurrent
/// access). `onRecordChanged` and `onRecordDeleted` are `@Sendable`
/// closures captured at init. Nothing mutates post-init, so the
/// reference can be shared across actor boundaries without a data
/// race; `@unchecked` only waives Swift's structural check that
/// `final class` types meet `Sendable`'s requirements automatically.
final class GRDBCSVImportProfileRepository: CSVImportProfileRepository, @unchecked Sendable {
  private let database: any DatabaseWriter
  private let onRecordChanged: @Sendable (String, UUID) -> Void
  private let onRecordDeleted: @Sendable (String, UUID) -> Void

  init(
    database: any DatabaseWriter,
    onRecordChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onRecordDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in }
  ) {
    self.database = database
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
  }

  // MARK: - CSVImportProfileRepository conformance

  func fetchAll() async throws -> [CSVImportProfile] {
    try await database.read { database in
      try CSVImportProfileRow
        .order(CSVImportProfileRow.Columns.createdAt.asc)
        .fetchAll(database)
        .map { $0.toDomain() }
    }
  }

  func create(_ profile: CSVImportProfile) async throws -> CSVImportProfile {
    let row = CSVImportProfileRow(domain: profile)
    try await database.write { database in
      try row.insert(database)
    }
    onRecordChanged(CSVImportProfileRow.recordType, profile.id)
    return row.toDomain()
  }

  func update(_ profile: CSVImportProfile) async throws -> CSVImportProfile {
    let updated = try await database.write { database -> CSVImportProfileRow in
      guard
        var existing =
          try CSVImportProfileRow
          .filter(CSVImportProfileRow.Columns.id == profile.id)
          .fetchOne(database)
      else {
        throw BackendError.serverError(404)
      }
      // Build a fresh row from the domain object and copy the
      // domain-mapped fields onto `existing` (preserving id,
      // recordName, createdAt, encodedSystemFields). Mirrors
      // `GRDBImportRuleRepository.update` so the field-mapping policy
      // lives only in `init(domain:)`.
      let fresh = CSVImportProfileRow(domain: profile)
      existing.accountId = fresh.accountId
      existing.parserIdentifier = fresh.parserIdentifier
      existing.headerSignature = fresh.headerSignature
      existing.filenamePattern = fresh.filenamePattern
      existing.deleteAfterImport = fresh.deleteAfterImport
      existing.lastUsedAt = fresh.lastUsedAt
      existing.dateFormatRawValue = fresh.dateFormatRawValue
      existing.columnRoleRawValuesEncoded = fresh.columnRoleRawValuesEncoded
      try existing.update(database)
      return existing
    }
    onRecordChanged(CSVImportProfileRow.recordType, profile.id)
    return updated.toDomain()
  }

  func delete(id: UUID) async throws {
    let didDelete = try await database.write { database in
      try CSVImportProfileRow.deleteOne(database, id: id)
    }
    guard didDelete else {
      throw BackendError.serverError(404)
    }
    onRecordDeleted(CSVImportProfileRow.recordType, id)
  }

  // MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
  //
  // Called from `ProfileDataSyncHandler` static dispatch tables on the
  // CKSyncEngine delegate's executor. `DatabaseWriter.write { db in … }`
  // has both async and sync overloads; the sync form blocks the calling
  // thread until the queue's serial executor admits the closure. Used
  // only off-MainActor; never call these synchronously from MainActor.

  func applyRemoteChangesSync(saved rows: [CSVImportProfileRow], deleted ids: [UUID]) throws {
    try database.write { database in
      for row in rows {
        // `upsert` matches on the PK conflict (`id`). Because
        // `recordName(for: id)` is total over `id`, the implied UNIQUE
        // conflict on `record_name` is satisfied by the same row, so a
        // single conflict target suffices.
        try row.upsert(database)
      }
      for id in ids {
        _ = try CSVImportProfileRow.deleteOne(database, id: id)
      }
    }
  }

  /// Writes (or clears) the cached system-fields blob on a single row.
  /// Returns `true` when a row was found and updated.
  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try CSVImportProfileRow
        .filter(CSVImportProfileRow.Columns.id == id)
        .updateAll(database, [CSVImportProfileRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  /// Clears `encoded_system_fields` on every row. Used after an
  /// `encryptedDataReset`.
  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try CSVImportProfileRow
        .updateAll(
          database,
          [CSVImportProfileRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  /// Returns IDs of rows whose `encoded_system_fields` is `NULL`.
  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try CSVImportProfileRow
        .filter(CSVImportProfileRow.Columns.encodedSystemFields == nil)
        .select(CSVImportProfileRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Returns IDs of every row in the table.
  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try CSVImportProfileRow
        .select(CSVImportProfileRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Looks up a single row by id. Used by the per-record upload path in
  /// `ProfileDataSyncHandler+RecordLookup`.
  func fetchRowSync(id: UUID) throws -> CSVImportProfileRow? {
    try database.read { database in
      try CSVImportProfileRow
        .filter(CSVImportProfileRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  /// Batch lookup by ids — used by the batch-build phase of
  /// `ProfileDataSyncHandler+RecordLookup`.
  func fetchRowsSync(ids: [UUID]) throws -> [CSVImportProfileRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try CSVImportProfileRow
        .filter(idSet.contains(CSVImportProfileRow.Columns.id))
        .fetchAll(database)
    }
  }

  /// Deletes every row in the table. Used by `deleteLocalData` after a
  /// remote zone deletion.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try CSVImportProfileRow.deleteAll(database)
    }
  }
}
