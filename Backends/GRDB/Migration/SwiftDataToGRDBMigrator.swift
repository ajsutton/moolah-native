// Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift

import Foundation
import GRDB
import OSLog
import SwiftData

/// One-shot migrator that copies CSV import profiles and import rules
/// from a profile's SwiftData store into its GRDB `data.sqlite` (the
/// `csv_import_profile` and `import_rule` tables added by
/// `v2_csv_import_and_rules`). Each record type is gated by an
/// independent `UserDefaults` flag so a partial migration never
/// re-runs against an already-populated table.
///
/// **Idempotency.** Set the flag *only* after the GRDB transaction
/// commits — a crash mid-write rolls the table back, the flag stays
/// unset, and the next launch re-runs from scratch.
///
/// **Bit-for-bit `encodedSystemFields`.** The migrator copies the cached
/// CKRecord change-tag blob byte-for-byte from the SwiftData row to the
/// GRDB row. Decoding it would lose precision (the round-trip of
/// `NSKeyedArchiver` outputs is not guaranteed identical) and trip a
/// `.serverRecordChanged` cycle on the first sync after migration.
///
/// **Hook point.** Called from `MoolahApp+Setup` after every active
/// `ProfileSession` has been opened and before
/// `SyncCoordinator.start()` so CKSyncEngine reads from a fully
/// populated `data.sqlite` on the first launch.
@MainActor
final class SwiftDataToGRDBMigrator {
  /// `UserDefaults` key gating the CSV-import-profile copy. Once true,
  /// the migrator skips this record type for the install's lifetime.
  static let csvImportProfilesFlag = "v2.csvImportProfiles.grdbMigrated"
  /// `UserDefaults` key gating the import-rule copy.
  static let importRulesFlag = "v2.importRules.grdbMigrated"

  private let logger = Logger(
    subsystem: "com.moolah.app", category: "SwiftDataToGRDBMigrator")

  init() {}

  /// Runs the one-shot migration for both record types. Each is gated
  /// independently; a previously-migrated record type is a no-op.
  ///
  /// `defaults` is injected with a `.standard` default so production
  /// callers pass nothing while tests supply an isolated suite (avoids
  /// the `CODE_GUIDE.md` §17 "no direct singleton access" rule).
  ///
  /// Synchronous because the only places it runs (per-profile session
  /// init and seed tests) need to block the calling thread until both
  /// SwiftData reads and GRDB writes complete. Total work is bounded
  /// by the row counts in the source SwiftData store — typically tens
  /// of rows for CSV import profiles + import rules combined.
  func migrateIfNeeded(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    defaults: UserDefaults = .standard
  ) throws {
    try migrateCSVImportProfilesIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try migrateImportRulesIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
  }

  // MARK: - CSV import profiles

  private func migrateCSVImportProfilesIfNeeded(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    defaults: UserDefaults
  ) throws {
    guard !defaults.bool(forKey: Self.csvImportProfilesFlag) else { return }
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<CSVImportProfileRecord>()
    let sourceRows: [CSVImportProfileRecord]
    do {
      sourceRows = try context.fetch(descriptor)
    } catch {
      logger.error(
        """
        SwiftData fetch for CSVImportProfileRecord failed during GRDB \
        migration: \(error.localizedDescription, privacy: .public). \
        Migration aborted; will retry next launch.
        """)
      throw error
    }
    let mappedRows = sourceRows.map(Self.mapCSVProfile(_:))
    if !mappedRows.isEmpty {
      try database.write { database in
        for row in mappedRows {
          try row.insert(database)
        }
      }
    }
    defaults.set(true, forKey: Self.csvImportProfilesFlag)
    logger.info(
      """
      SwiftData → GRDB migration complete for CSVImportProfile: \
      \(mappedRows.count, privacy: .public) row(s) copied
      """)
  }

  /// Maps a SwiftData `CSVImportProfileRecord` to a `CSVImportProfileRow`,
  /// preserving `encodedSystemFields` byte-for-byte and re-deriving
  /// `record_name` from the canonical CloudKit recordName format.
  private static func mapCSVProfile(_ source: CSVImportProfileRecord) -> CSVImportProfileRow {
    CSVImportProfileRow(
      id: source.id,
      recordName: CSVImportProfileRow.recordName(for: source.id),
      accountId: source.accountId,
      parserIdentifier: source.parserIdentifier,
      headerSignature: source.headerSignature,
      filenamePattern: source.filenamePattern,
      deleteAfterImport: source.deleteAfterImport,
      createdAt: source.createdAt,
      lastUsedAt: source.lastUsedAt,
      dateFormatRawValue: source.dateFormatRawValue,
      columnRoleRawValuesEncoded: source.columnRoleRawValuesEncoded,
      encodedSystemFields: source.encodedSystemFields)
  }

  // MARK: - Import rules

  private func migrateImportRulesIfNeeded(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    defaults: UserDefaults
  ) throws {
    guard !defaults.bool(forKey: Self.importRulesFlag) else { return }
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<ImportRuleRecord>()
    let sourceRows: [ImportRuleRecord]
    do {
      sourceRows = try context.fetch(descriptor)
    } catch {
      logger.error(
        """
        SwiftData fetch for ImportRuleRecord failed during GRDB \
        migration: \(error.localizedDescription, privacy: .public). \
        Migration aborted; will retry next launch.
        """)
      throw error
    }
    let mappedRows = sourceRows.map(Self.mapImportRule(_:))
    if !mappedRows.isEmpty {
      try database.write { database in
        for row in mappedRows {
          try row.insert(database)
        }
      }
    }
    defaults.set(true, forKey: Self.importRulesFlag)
    logger.info(
      """
      SwiftData → GRDB migration complete for ImportRule: \
      \(mappedRows.count, privacy: .public) row(s) copied
      """)
  }

  /// Maps a SwiftData `ImportRuleRecord` to an `ImportRuleRow`, preserving
  /// `encodedSystemFields` and the JSON blob bytes for conditions/actions
  /// byte-for-byte (no decode/encode cycle — see file header).
  private static func mapImportRule(_ source: ImportRuleRecord) -> ImportRuleRow {
    ImportRuleRow(
      id: source.id,
      recordName: ImportRuleRow.recordName(for: source.id),
      name: source.name,
      enabled: source.enabled,
      position: source.position,
      matchMode: source.matchMode,
      conditionsJSON: source.conditionsJSON,
      actionsJSON: source.actionsJSON,
      accountScope: source.accountScope,
      encodedSystemFields: source.encodedSystemFields)
  }
}
