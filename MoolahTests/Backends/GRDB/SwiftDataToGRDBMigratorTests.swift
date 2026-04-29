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
@Suite("SwiftData → GRDB migrator", .serialized)
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

  // MARK: - Failure paths
  //
  // These tests force the GRDB write to throw and assert the
  // `committed` defer-flag invariant: the `UserDefaults` flag must NOT
  // be set when the write fails, so the next launch retries the
  // migration. A regression where `committed = true` moves above the
  // write block would silently fail without these tests.

  @Test("CSV migration: GRDB write failure leaves the flag unset for retry")
  func csvImportProfileMigrationFailureKeepsFlagUnset() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let context = ModelContext(container)
    context.insert(
      CSVImportProfileRecord(
        id: UUID(), accountId: UUID(),
        parserIdentifier: "p", headerSignature: ["a"]))
    try context.save()

    // Force the inserts inside `migrateCSVImportProfilesIfNeeded` to fail
    // by installing a BEFORE-INSERT trigger that aborts. The migrator's
    // `committed = true` line runs *after* the write block; if the write
    // throws, the flag must stay false.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER abort_csv_migration
          BEFORE INSERT ON csv_import_profile
          BEGIN SELECT RAISE(ABORT, 'forced'); END;
          """)
    }

    let defaults = makeIsolatedDefaults()
    let migrator = SwiftDataToGRDBMigrator()
    #expect(throws: (any Error).self) {
      try migrator.migrateIfNeeded(
        modelContainer: container, database: database, defaults: defaults)
    }
    #expect(
      !defaults.bool(forKey: SwiftDataToGRDBMigrator.csvImportProfilesFlag),
      "CSV flag must remain false so the next launch retries")
    #expect(
      !defaults.bool(forKey: SwiftDataToGRDBMigrator.importRulesFlag),
      "Rules flag must also remain false — CSV step throws before rules step runs")
  }

  @Test("Import-rule migration: GRDB write failure leaves the flag unset for retry")
  func importRuleMigrationFailureKeepsFlagUnset() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let context = ModelContext(container)
    context.insert(
      ImportRuleRecord(
        id: UUID(), name: "X", enabled: true, position: 0,
        matchMode: .all, conditions: [], actions: [],
        accountScope: nil))
    try context.save()

    // Trigger only on the import_rule table so the CSV migration
    // succeeds and the rule step is the one that throws.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER abort_rule_migration
          BEFORE INSERT ON import_rule
          BEGIN SELECT RAISE(ABORT, 'forced'); END;
          """)
    }

    let defaults = makeIsolatedDefaults()
    let migrator = SwiftDataToGRDBMigrator()
    #expect(throws: (any Error).self) {
      try migrator.migrateIfNeeded(
        modelContainer: container, database: database, defaults: defaults)
    }
    // CSV step succeeded (no CSV source rows); flag set is allowed.
    // Rules step threw; its flag MUST stay false for retry.
    #expect(
      !defaults.bool(forKey: SwiftDataToGRDBMigrator.importRulesFlag),
      "Rules flag must remain false so the next launch retries")
  }

  // MARK: - Core financial graph: Instruments

  @Test("copies instrument rows + system fields byte-for-byte")
  func instrumentMigration() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let context = ModelContext(container)
    let systemFields = Data([0x01, 0x02, 0x03])
    let source = InstrumentRecord(
      id: "ASX:BHP.AX",
      kind: "stock",
      name: "BHP",
      decimals: 4,
      ticker: "BHP.AX",
      exchange: "ASX")
    source.encodedSystemFields = systemFields
    context.insert(source)
    try context.save()

    let defaults = makeIsolatedDefaults()
    try SwiftDataToGRDBMigrator().migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.instrumentsFlag))

    let row = try await database.read { database in
      try InstrumentRow.filter(InstrumentRow.Columns.id == "ASX:BHP.AX")
        .fetchOne(database)
    }
    let resolved = try #require(row)
    #expect(resolved.kind == "stock")
    #expect(resolved.ticker == "BHP.AX")
    #expect(resolved.exchange == "ASX")
    #expect(resolved.encodedSystemFields == systemFields)
  }

  @Test("instrument migration is idempotent on re-run")
  func instrumentMigrationIdempotent() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let context = ModelContext(container)
    context.insert(
      InstrumentRecord(id: "AUD", kind: "fiatCurrency", name: "AUD", decimals: 2))
    try context.save()

    let defaults = makeIsolatedDefaults()
    let migrator = SwiftDataToGRDBMigrator()
    try migrator.migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)
    try migrator.migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)

    let count = try await database.read { database in
      try InstrumentRow.fetchCount(database)
    }
    #expect(count == 1, "Second run must not double-insert")
  }

  // MARK: - Core financial graph: Categories

  @Test("copies category rows preserving parent_id self-references")
  func categoryMigration() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let context = ModelContext(container)
    let parentId = UUID()
    let childId = UUID()
    let parent = CategoryRecord(id: parentId, name: "Food", parentId: nil)
    parent.encodedSystemFields = Data([0xAB])
    context.insert(parent)
    context.insert(CategoryRecord(id: childId, name: "Groceries", parentId: parentId))
    try context.save()

    let defaults = makeIsolatedDefaults()
    try SwiftDataToGRDBMigrator().migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.categoriesFlag))

    try await database.read { database in
      let parentRow = try #require(
        try CategoryRow.filter(CategoryRow.Columns.id == parentId).fetchOne(database))
      let childRow = try #require(
        try CategoryRow.filter(CategoryRow.Columns.id == childId).fetchOne(database))
      #expect(parentRow.parentId == nil)
      #expect(childRow.parentId == parentId)
      #expect(parentRow.encodedSystemFields == Data([0xAB]))
    }
  }

  // MARK: - Core financial graph: Accounts

  @Test("copies account rows + system fields byte-for-byte")
  func accountMigration() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let context = ModelContext(container)
    let id = UUID()
    let systemFields = Data([0xCA, 0xFE])
    let source = AccountRecord(
      id: id, name: "Checking", type: "bank",
      instrumentId: "AUD", position: 5, isHidden: false)
    source.encodedSystemFields = systemFields
    context.insert(source)
    try context.save()

    let defaults = makeIsolatedDefaults()
    try SwiftDataToGRDBMigrator().migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.accountsFlag))

    let row = try await database.read { database in
      try AccountRow.filter(AccountRow.Columns.id == id).fetchOne(database)
    }
    let resolved = try #require(row)
    #expect(resolved.name == "Checking")
    #expect(resolved.type == "bank")
    #expect(resolved.instrumentId == "AUD")
    #expect(resolved.position == 5)
    #expect(resolved.encodedSystemFields == systemFields)
  }

  // MARK: - Core financial graph: Earmarks

  @Test("copies earmark rows + system fields byte-for-byte")
  func earmarkMigration() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let context = ModelContext(container)
    let id = UUID()
    let source = EarmarkRecord(
      id: id, name: "Trip", position: 2, instrumentId: "AUD")
    source.encodedSystemFields = Data([0xDE, 0xAD])
    context.insert(source)
    try context.save()

    let defaults = makeIsolatedDefaults()
    try SwiftDataToGRDBMigrator().migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.earmarksFlag))

    let row = try await database.read { database in
      try EarmarkRow.filter(EarmarkRow.Columns.id == id).fetchOne(database)
    }
    let resolved = try #require(row)
    #expect(resolved.name == "Trip")
    #expect(resolved.instrumentId == "AUD")
    #expect(resolved.encodedSystemFields == Data([0xDE, 0xAD]))
  }

  // MARK: - Core financial graph: Earmark budget items

  @Test("copies earmark budget items preserving FK references")
  func earmarkBudgetItemMigration() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let context = ModelContext(container)
    let earmarkId = UUID()
    let categoryId = UUID()
    let itemId = UUID()
    context.insert(EarmarkRecord(id: earmarkId, name: "Trip", instrumentId: "AUD"))
    context.insert(CategoryRecord(id: categoryId, name: "Food", parentId: nil))
    context.insert(
      EarmarkBudgetItemRecord(
        id: itemId, earmarkId: earmarkId, categoryId: categoryId,
        amount: 5000, instrumentId: "AUD"))
    try context.save()

    let defaults = makeIsolatedDefaults()
    try SwiftDataToGRDBMigrator().migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.earmarkBudgetItemsFlag))

    let row = try await database.read { database in
      try EarmarkBudgetItemRow.filter(EarmarkBudgetItemRow.Columns.id == itemId)
        .fetchOne(database)
    }
    let resolved = try #require(row)
    #expect(resolved.earmarkId == earmarkId)
    #expect(resolved.categoryId == categoryId)
    #expect(resolved.amount == 5000)
    #expect(resolved.instrumentId == "AUD")
  }

  // MARK: - Core financial graph: Investment values

  @Test("copies investment value rows preserving account FK")
  func investmentValueMigration() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let context = ModelContext(container)
    let accountId = UUID()
    let valueId = UUID()
    context.insert(AccountRecord(id: accountId, name: "Brokerage", type: "investment"))
    context.insert(
      InvestmentValueRecord(
        id: valueId, accountId: accountId,
        date: Date(timeIntervalSince1970: 1_700_000_000),
        value: 12345, instrumentId: "AUD"))
    try context.save()

    let defaults = makeIsolatedDefaults()
    try SwiftDataToGRDBMigrator().migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.investmentValuesFlag))

    let row = try await database.read { database in
      try InvestmentValueRow.filter(InvestmentValueRow.Columns.id == valueId)
        .fetchOne(database)
    }
    let resolved = try #require(row)
    #expect(resolved.accountId == accountId)
    #expect(resolved.value == 12345)
  }

  // MARK: - Core financial graph: Transactions + Legs

  @Test("copies transaction header + legs preserving FK references")
  func transactionAndLegMigration() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let context = ModelContext(container)
    let accountId = UUID()
    let txnId = UUID()
    let legId = UUID()
    context.insert(AccountRecord(id: accountId, name: "Cash", type: "bank"))
    let txn = TransactionRecord(id: txnId, date: Date(), payee: "Coffee")
    txn.encodedSystemFields = Data([0x12, 0x34])
    context.insert(txn)
    let leg = TransactionLegRecord(
      id: legId, transactionId: txnId, accountId: accountId,
      instrumentId: "AUD", quantity: -500, type: "expense",
      categoryId: nil, sortOrder: 0)
    context.insert(leg)
    try context.save()

    let defaults = makeIsolatedDefaults()
    try SwiftDataToGRDBMigrator().migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.transactionsFlag))
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.transactionLegsFlag))

    try await database.read { database in
      let txnRow = try #require(
        try TransactionRow.filter(TransactionRow.Columns.id == txnId)
          .fetchOne(database))
      let legRow = try #require(
        try TransactionLegRow.filter(TransactionLegRow.Columns.id == legId)
          .fetchOne(database))
      #expect(txnRow.payee == "Coffee")
      #expect(txnRow.encodedSystemFields == Data([0x12, 0x34]))
      #expect(legRow.transactionId == txnId)
      #expect(legRow.accountId == accountId)
      #expect(legRow.quantity == -500)
      #expect(legRow.type == "expense")
    }
  }

  // MARK: - Cross-FK migration

  @Test("migrating all eight types preserves cross-FK references in dependency order")
  func crossFKMigration() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let context = ModelContext(container)
    // Build a small graph that exercises every FK on every table.
    let aud = "AUD"
    context.insert(InstrumentRecord(id: aud, kind: "fiatCurrency", name: aud, decimals: 2))
    let parentCategoryId = UUID()
    let childCategoryId = UUID()
    context.insert(CategoryRecord(id: parentCategoryId, name: "Food", parentId: nil))
    context.insert(
      CategoryRecord(id: childCategoryId, name: "Groceries", parentId: parentCategoryId))
    let accountId = UUID()
    context.insert(
      AccountRecord(id: accountId, name: "Checking", type: "bank", instrumentId: aud))
    let earmarkId = UUID()
    context.insert(EarmarkRecord(id: earmarkId, name: "Holiday", instrumentId: aud))
    context.insert(
      EarmarkBudgetItemRecord(
        id: UUID(), earmarkId: earmarkId, categoryId: parentCategoryId,
        amount: 100, instrumentId: aud))
    let valueId = UUID()
    context.insert(
      InvestmentValueRecord(
        id: valueId, accountId: accountId, date: Date(),
        value: 1000, instrumentId: aud))
    let txnId = UUID()
    context.insert(TransactionRecord(id: txnId, date: Date(), payee: "Lunch"))
    context.insert(
      TransactionLegRecord(
        id: UUID(), transactionId: txnId, accountId: accountId,
        instrumentId: aud, quantity: -100, type: "expense",
        categoryId: childCategoryId, sortOrder: 0))
    try context.save()

    let defaults = makeIsolatedDefaults()
    try SwiftDataToGRDBMigrator().migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)

    // Every flag should be set; every FK-bearing row should resolve its
    // parent under the target schema's enforced FKs (PRAGMA
    // foreign_keys = ON), so a missing-parent failure would have surfaced
    // as a trapped write inside the migrator.
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.instrumentsFlag))
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.categoriesFlag))
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.accountsFlag))
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.earmarksFlag))
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.earmarkBudgetItemsFlag))
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.investmentValuesFlag))
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.transactionsFlag))
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.transactionLegsFlag))

    // Check FK preservation on the rows that reference parents.
    try await database.read { database in
      let childCategory = try #require(
        try CategoryRow.filter(CategoryRow.Columns.id == childCategoryId)
          .fetchOne(database))
      #expect(childCategory.parentId == parentCategoryId)
      let value = try #require(
        try InvestmentValueRow
          .filter(InvestmentValueRow.Columns.id == valueId)
          .fetchOne(database))
      #expect(value.accountId == accountId)
      let leg = try #require(
        try TransactionLegRow
          .filter(TransactionLegRow.Columns.transactionId == txnId)
          .fetchOne(database))
      #expect(leg.categoryId == childCategoryId)
      #expect(leg.accountId == accountId)
    }
  }
}
