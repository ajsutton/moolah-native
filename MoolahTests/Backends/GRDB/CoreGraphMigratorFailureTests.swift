// MoolahTests/Backends/GRDB/CoreGraphMigratorFailureTests.swift

import Foundation
import GRDB
import SwiftData
import Testing

@testable import Moolah

/// Failure-path coverage for the eight per-type core-graph migrators
/// (instruments, categories, accounts, earmarks, earmark budget items,
/// investment values, transactions, transaction legs). Lives in its own
/// file so `SwiftDataToGRDBMigratorCoreGraphTests` stays under the
/// `type_body_length` cap.
@Suite("SwiftData → GRDB migrator — core-graph failure", .serialized)
@MainActor
struct CoreGraphMigratorFailureTests {
  private func makeIsolatedDefaults() -> UserDefaults {
    let suite = "migrator-core-graph-failure-\(UUID().uuidString)"
    return UserDefaults(suiteName: suite) ?? .standard
  }

  /// Pins the `committed = false` invariant for the eight per-type
  /// core-graph migrators: when the very first per-type write fails, no
  /// downstream migrator runs, no `*Flag` UserDefaults key flips, and
  /// the GRDB tables stay empty so the next launch re-runs the chain.
  /// One test against the first link in the chain (`instrument`) covers
  /// the shared `committed`/`defer` pattern for all eight; instruments
  /// runs first in `migrateIfNeeded`, so any failure on its insert
  /// aborts the rest of the pipeline.
  @Test("core-graph migration: GRDB write failure leaves every flag unset for retry")
  func coreGraphMigrationFailureKeepsFlagsUnset() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let context = ModelContext(container)
    context.insert(
      InstrumentRecord(id: "AUD", kind: "fiatCurrency", name: "AUD", decimals: 2))
    try context.save()

    // Force the insert inside `migrateInstrumentsIfNeeded` to fail by
    // installing a BEFORE-INSERT trigger that aborts. `RAISE(ABORT, ...)`
    // propagates as a thrown error even with `onConflict: .ignore`
    // (IGNORE suppresses conflict-resolution errors, not RAISE(ABORT)).
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER abort_instrument_migration
          BEFORE INSERT ON instrument
          BEGIN SELECT RAISE(ABORT, 'forced'); END;
          """)
    }

    let defaults = makeIsolatedDefaults()
    await #expect(throws: (any Error).self) {
      try await SwiftDataToGRDBMigrator().migrateIfNeeded(
        modelContainer: container, database: database, defaults: defaults)
    }

    // Every per-type flag must remain false so the next launch retries.
    #expect(!defaults.bool(forKey: SwiftDataToGRDBMigrator.instrumentsFlag))
    #expect(!defaults.bool(forKey: SwiftDataToGRDBMigrator.categoriesFlag))
    #expect(!defaults.bool(forKey: SwiftDataToGRDBMigrator.accountsFlag))
    #expect(!defaults.bool(forKey: SwiftDataToGRDBMigrator.earmarksFlag))
    #expect(!defaults.bool(forKey: SwiftDataToGRDBMigrator.earmarkBudgetItemsFlag))
    #expect(!defaults.bool(forKey: SwiftDataToGRDBMigrator.investmentValuesFlag))
    #expect(!defaults.bool(forKey: SwiftDataToGRDBMigrator.transactionsFlag))
    #expect(!defaults.bool(forKey: SwiftDataToGRDBMigrator.transactionLegsFlag))
    let count = try await database.read { reader in
      try InstrumentRow.fetchCount(reader)
    }
    #expect(count == 0, "Failed write must leave the instrument table empty")
  }
}
