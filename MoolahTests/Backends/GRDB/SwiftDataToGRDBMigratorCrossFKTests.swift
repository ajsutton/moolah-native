// MoolahTests/Backends/GRDB/SwiftDataToGRDBMigratorCrossFKTests.swift

import Foundation
import GRDB
import SwiftData
import Testing

@testable import Moolah

/// End-to-end SwiftData → GRDB migration test that drives the eight
/// per-type migrators in dependency order against a graph that
/// exercises every cross-table FK on every table.
///
/// Sibling to `SwiftDataToGRDBMigratorCoreGraphTests.swift` (per-type
/// tests) and `SwiftDataToGRDBMigratorTests.swift` (CSV / rules /
/// failure paths).
@Suite("SwiftData → GRDB migrator — cross-FK end-to-end", .serialized)
@MainActor
struct SwiftDataToGRDBMigratorCrossFKTests {

  private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "com.moolah.migrator-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  /// Identifiers seeded into SwiftData ahead of the migration; pulled
  /// onto a fixture struct so the test body itself stays under the
  /// function-body-length limit and the post-migration assertions can
  /// reference the same names.
  private struct CrossFKIds {
    let parentCategoryId = UUID()
    let childCategoryId = UUID()
    let accountId = UUID()
    let earmarkId = UUID()
    let valueId = UUID()
    let txnId = UUID()
  }

  /// Inserts the SwiftData side of the test graph: the eight FK-bearing
  /// records that exercise every cross-table FK on every table.
  private static func seedCrossFKSwiftDataGraph(
    context: ModelContext,
    ids: CrossFKIds
  ) throws {
    let aud = "AUD"
    context.insert(InstrumentRecord(id: aud, kind: "fiatCurrency", name: aud, decimals: 2))
    context.insert(CategoryRecord(id: ids.parentCategoryId, name: "Food", parentId: nil))
    context.insert(
      CategoryRecord(
        id: ids.childCategoryId, name: "Groceries", parentId: ids.parentCategoryId))
    context.insert(
      AccountRecord(id: ids.accountId, name: "Checking", type: "bank", instrumentId: aud))
    context.insert(EarmarkRecord(id: ids.earmarkId, name: "Holiday", instrumentId: aud))
    context.insert(
      EarmarkBudgetItemRecord(
        id: UUID(), earmarkId: ids.earmarkId, categoryId: ids.parentCategoryId,
        amount: 100, instrumentId: aud))
    context.insert(
      InvestmentValueRecord(
        id: ids.valueId, accountId: ids.accountId, date: Date(),
        value: 1000, instrumentId: aud))
    context.insert(TransactionRecord(id: ids.txnId, date: Date(), payee: "Lunch"))
    context.insert(
      TransactionLegRecord(
        id: UUID(), transactionId: ids.txnId, accountId: ids.accountId,
        instrumentId: aud, quantity: -100, type: "expense",
        categoryId: ids.childCategoryId, sortOrder: 0))
    try context.save()
  }

  /// Reads the FK-bearing rows from GRDB and asserts every one of them
  /// resolved its parent — the schema's enforced FKs would have trapped
  /// inside the migrator if any parent was missing, but reading the
  /// values back gives us a positive signal too.
  private static func expectCrossFKReferencesPreserved(
    in database: any DatabaseReader,
    ids: CrossFKIds
  ) async throws {
    try await database.read { database in
      let childCategory = try #require(
        try CategoryRow.filter(CategoryRow.Columns.id == ids.childCategoryId)
          .fetchOne(database))
      #expect(childCategory.parentId == ids.parentCategoryId)
      let value = try #require(
        try InvestmentValueRow
          .filter(InvestmentValueRow.Columns.id == ids.valueId)
          .fetchOne(database))
      #expect(value.accountId == ids.accountId)
      let leg = try #require(
        try TransactionLegRow
          .filter(TransactionLegRow.Columns.transactionId == ids.txnId)
          .fetchOne(database))
      #expect(leg.categoryId == ids.childCategoryId)
      #expect(leg.accountId == ids.accountId)
    }
  }

  @Test("migrating all eight types preserves cross-FK references in dependency order")
  func crossFKMigration() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let context = ModelContext(container)
    let ids = CrossFKIds()
    try Self.seedCrossFKSwiftDataGraph(context: context, ids: ids)

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

    try await Self.expectCrossFKReferencesPreserved(in: database, ids: ids)
  }
}
