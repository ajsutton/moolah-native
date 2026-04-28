// Backends/GRDB/Repositories/GRDBImportRuleRepository.swift

import Foundation
import GRDB

/// GRDB-backed implementation of `ImportRuleRepository`. Replaces the
/// SwiftData-backed `CloudKitImportRuleRepository` for the `import_rule`
/// table introduced by `v2_csv_import_and_rules`.
///
/// Concurrency: see header on `GRDBCSVImportProfileRepository`.
/// `final class @unchecked Sendable` to keep CKSyncEngine sync entry
/// points synchronous; protocol conformance still uses `async throws`.
final class GRDBImportRuleRepository: ImportRuleRepository, @unchecked Sendable {
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

  // MARK: - ImportRuleRepository conformance

  func fetchAll() async throws -> [ImportRule] {
    let rows = try await database.read { database in
      try ImportRuleRow
        .order(ImportRuleRow.Columns.position.asc)
        .fetchAll(database)
    }
    return rows.map { $0.toDomain() }
  }

  func create(_ rule: ImportRule) async throws -> ImportRule {
    let row = ImportRuleRow(domain: rule)
    try await database.write { database in
      try row.insert(database)
    }
    onRecordChanged(ImportRuleRow.recordType, rule.id)
    return row.toDomain()
  }

  func update(_ rule: ImportRule) async throws -> ImportRule {
    let updated = try await database.write { database -> ImportRuleRow in
      guard
        var existing =
          try ImportRuleRow
          .filter(ImportRuleRow.Columns.id == rule.id)
          .fetchOne(database)
      else {
        throw BackendError.serverError(404)
      }
      let fresh = ImportRuleRow(domain: rule)
      existing.name = fresh.name
      existing.enabled = fresh.enabled
      existing.position = fresh.position
      existing.matchMode = fresh.matchMode
      existing.conditionsJSON = fresh.conditionsJSON
      existing.actionsJSON = fresh.actionsJSON
      existing.accountScope = fresh.accountScope
      try existing.update(database)
      return existing
    }
    onRecordChanged(ImportRuleRow.recordType, rule.id)
    return updated.toDomain()
  }

  func delete(id: UUID) async throws {
    let didDelete = try await database.write { database in
      try ImportRuleRow.deleteOne(database, id: id)
    }
    guard didDelete else {
      throw BackendError.serverError(404)
    }
    onRecordDeleted(ImportRuleRow.recordType, id)
  }

  /// Atomically renumber `position` across every existing rule so that
  /// `orderedIds` take positions 0…n-1. Throws
  /// `BackendError.serverError(409)` if the passed ids do not exactly
  /// match the set of stored rule ids. Only ids whose position actually
  /// changed are queued for upload.
  func reorder(_ orderedIds: [UUID]) async throws {
    let changedIds = try await database.write { database -> [UUID] in
      let allRows = try ImportRuleRow.fetchAll(database)
      let storedIds = Set(allRows.map(\.id))
      let requestedIds = Set(orderedIds)
      guard storedIds == requestedIds, allRows.count == orderedIds.count else {
        throw BackendError.serverError(409)
      }
      let indexById = Dictionary(
        uniqueKeysWithValues: orderedIds.enumerated().map { ($1, $0) })
      var changed: [UUID] = []
      for var row in allRows {
        let newPosition = indexById[row.id] ?? row.position
        if row.position != newPosition {
          row.position = newPosition
          try row.update(database)
          changed.append(row.id)
        }
      }
      return changed
    }
    for id in changedIds { onRecordChanged(ImportRuleRow.recordType, id) }
  }

  // MARK: - Sync entry points (synchronous, GRDB-queue-blocking)

  func applyRemoteChangesSync(saved rows: [ImportRuleRow], deleted ids: [UUID]) throws {
    try database.write { database in
      for row in rows {
        // `upsert` matches on the PK conflict (`id`). Because
        // `recordName(for: id)` is total over `id`, the implied UNIQUE
        // conflict on `record_name` is satisfied by the same row, so a
        // single conflict target suffices.
        try row.upsert(database)
      }
      for id in ids {
        _ = try ImportRuleRow.deleteOne(database, id: id)
      }
    }
  }

  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try ImportRuleRow
        .filter(ImportRuleRow.Columns.id == id)
        .updateAll(database, [ImportRuleRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try ImportRuleRow
        .updateAll(
          database,
          [ImportRuleRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try ImportRuleRow
        .filter(ImportRuleRow.Columns.encodedSystemFields == nil)
        .select(ImportRuleRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try ImportRuleRow
        .select(ImportRuleRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  func fetchRowSync(id: UUID) throws -> ImportRuleRow? {
    try database.read { database in
      try ImportRuleRow
        .filter(ImportRuleRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  func fetchRowsSync(ids: [UUID]) throws -> [ImportRuleRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try ImportRuleRow
        .filter(idSet.contains(ImportRuleRow.Columns.id))
        .fetchAll(database)
    }
  }

  func deleteAllSync() throws {
    try database.write { database in
      _ = try ImportRuleRow.deleteAll(database)
    }
  }
}
