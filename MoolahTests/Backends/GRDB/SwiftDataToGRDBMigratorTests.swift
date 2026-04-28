// MoolahTests/Backends/GRDB/SwiftDataToGRDBMigratorTests.swift

import Foundation
import GRDB
import SwiftData
import Testing

@testable import Moolah

/// Tests for the one-shot SwiftData → GRDB migrator that copies CSV
/// import profiles and import rules into `data.sqlite` on first launch
/// after slice 0 of `plans/grdb-migration.md`.
///
/// Each test runs against an isolated `UserDefaults` suite so the
/// per-record-type migration flags don't bleed across tests.
@Suite("SwiftData → GRDB migrator")
@MainActor
struct SwiftDataToGRDBMigratorTests {

  // MARK: - Helpers

  private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "com.moolah.migrator-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  // MARK: - CSV import profiles

  @Test("copies CSV import profile rows + system fields byte-for-byte")
  func csvImportProfileMigration() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let context = ModelContext(container)
    let id = UUID()
    let accountId = UUID()
    let systemFields = Data([0xCA, 0xFE, 0xBA, 0xBE])
    let source = CSVImportProfileRecord(
      id: id,
      accountId: accountId,
      parserIdentifier: "generic-bank",
      headerSignature: ["date", "amount", "description"],
      filenamePattern: "cba-*.csv",
      deleteAfterImport: true,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastUsedAt: Date(timeIntervalSince1970: 1_700_100_000),
      dateFormatRawValue: "yyyy-MM-dd",
      columnRoleRawValuesEncoded: nil)
    source.encodedSystemFields = systemFields
    context.insert(source)
    try context.save()

    let defaults = makeIsolatedDefaults()
    let migrator = SwiftDataToGRDBMigrator()
    try migrator.migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)

    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.csvImportProfilesFlag))

    let rows = try await database.read { database in
      try CSVImportProfileRow.fetchAll(database)
    }
    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(row.id == id)
    #expect(row.recordName == "CSVImportProfileRecord|\(id.uuidString)")
    #expect(row.accountId == accountId)
    #expect(row.parserIdentifier == "generic-bank")
    #expect(row.headerSignature == "date\u{1F}amount\u{1F}description")
    #expect(row.filenamePattern == "cba-*.csv")
    #expect(row.deleteAfterImport == true)
    #expect(row.dateFormatRawValue == "yyyy-MM-dd")
    #expect(row.columnRoleRawValuesEncoded == nil)
    #expect(row.encodedSystemFields == systemFields)
  }

  @Test("re-running the migrator is a no-op once the flag is set")
  func reRunIsNoOp() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let context = ModelContext(container)
    let original = CSVImportProfileRecord(
      id: UUID(),
      accountId: UUID(),
      parserIdentifier: "p",
      headerSignature: ["a"])
    context.insert(original)
    try context.save()

    let defaults = makeIsolatedDefaults()
    let migrator = SwiftDataToGRDBMigrator()
    try migrator.migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)

    // Add a row to SwiftData after the flag is set: a true no-op should
    // leave it untouched on disk in GRDB.
    let extra = CSVImportProfileRecord(
      id: UUID(),
      accountId: UUID(),
      parserIdentifier: "p2",
      headerSignature: ["b"])
    context.insert(extra)
    try context.save()

    try migrator.migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)

    let count = try await database.read { database in
      try CSVImportProfileRow.fetchCount(database)
    }
    #expect(count == 1, "Second run must not double-insert nor pick up new SwiftData rows")
  }

  // MARK: - Import rules

  @Test("copies import-rule rows + JSON blobs byte-for-byte")
  func importRuleMigration() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let context = ModelContext(container)
    let id = UUID()
    let accountScope = UUID()
    let systemFields = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let conditionsJSON = Data(#"[{"field":"payee"}]"#.utf8)
    let actionsJSON = Data(#"[{"set":"category"}]"#.utf8)
    let source = ImportRuleRecord(
      id: id,
      name: "Coffee",
      enabled: true,
      position: 7,
      matchMode: .all,
      conditions: [],
      actions: [],
      accountScope: accountScope)
    source.conditionsJSON = conditionsJSON
    source.actionsJSON = actionsJSON
    source.encodedSystemFields = systemFields
    context.insert(source)
    try context.save()

    let defaults = makeIsolatedDefaults()
    let migrator = SwiftDataToGRDBMigrator()
    try migrator.migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)

    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.importRulesFlag))

    let rows = try await database.read { database in
      try ImportRuleRow.fetchAll(database)
    }
    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(row.id == id)
    #expect(row.recordName == "ImportRuleRecord|\(id.uuidString)")
    #expect(row.name == "Coffee")
    #expect(row.enabled)
    #expect(row.position == 7)
    #expect(row.matchMode == "all")
    #expect(row.conditionsJSON == conditionsJSON)
    #expect(row.actionsJSON == actionsJSON)
    #expect(row.accountScope == accountScope)
    #expect(row.encodedSystemFields == systemFields)
  }

  @Test("empty SwiftData store yields zero GRDB rows but still sets the flags")
  func emptySourceSetsFlags() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let defaults = makeIsolatedDefaults()
    let migrator = SwiftDataToGRDBMigrator()
    try migrator.migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)

    let csvCount = try await database.read { database in
      try CSVImportProfileRow.fetchCount(database)
    }
    let ruleCount = try await database.read { database in
      try ImportRuleRow.fetchCount(database)
    }
    #expect(csvCount == 0)
    #expect(ruleCount == 0)
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.csvImportProfilesFlag))
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.importRulesFlag))
  }
}
