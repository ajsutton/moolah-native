// MoolahTests/Backends/GRDB/SwiftDataToGRDBMigratorCoreGraphTests.swift

import Foundation
import GRDB
import SwiftData
import Testing

@testable import Moolah

/// Per-type SwiftData → GRDB migration tests for the core financial
/// graph (instruments, categories, accounts, earmarks, earmark budget
/// items, investment values, transactions + legs).
///
/// Sibling files: `SwiftDataToGRDBMigratorTests.swift` keeps the
/// CSV-import-profile / import-rule tests, the failure-path tests, and
/// the shared `makeIsolatedDefaults()` helper.
/// `SwiftDataToGRDBMigratorCrossFKTests.swift` drives the eight
/// migrators end-to-end against a graph that exercises every cross-FK.
///
/// Each test runs against an isolated `UserDefaults` suite so the
/// per-record-type migration flags don't bleed across tests.
@Suite("SwiftData → GRDB migrator — core financial graph", .serialized)
@MainActor
struct SwiftDataToGRDBMigratorCoreGraphTests {

  // MARK: - Helpers

  private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "com.moolah.migrator-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
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

}
