// MoolahTests/Backends/GRDB/SwiftDataToGRDBMigratorProfileIndexTests.swift

import Foundation
import GRDB
import SwiftData
import Testing

@testable import Moolah

/// Tests for the one-shot SwiftData → GRDB migrator that copies
/// `ProfileRecord` rows into the app-scoped `profile-index.sqlite` on
/// first launch.
///
/// The profile-index migrator runs against a different
/// `ModelContainer` (the index container) and a different
/// `DatabaseWriter` (the profile-index queue) than the per-profile
/// migrators, so it has its own entry point and its own test suite.
///
/// Each test runs against an isolated `UserDefaults` suite so the
/// per-record-type migration flag does not bleed across tests.
@Suite("SwiftData → GRDB profile-index migrator", .serialized)
@MainActor
struct SwiftDataToGRDBMigratorProfileIndexTests {

  // MARK: - Helpers

  private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "com.moolah.profile-index-migrator-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  /// In-memory SwiftData container that mirrors the production index
  /// container's schema (just `ProfileRecord`). `cloudKitDatabase: .none`
  /// is critical: the test binary is signed with iCloud entitlements,
  /// so the default `.automatic` would attach CoreData+CloudKit
  /// mirroring to the in-memory store and import live records before
  /// the test could read its own seed.
  private func makeIndexContainer() throws -> ModelContainer {
    let schema = Schema([ProfileRecord.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    return try ModelContainer(for: schema, configurations: [config])
  }

  // MARK: - Happy path

  @Test("copies ProfileRecord rows + system fields byte-for-byte")
  func profileIndexMigration() async throws {
    let container = try makeIndexContainer()
    let database = try ProfileIndexDatabase.openInMemory()
    let context = ModelContext(container)

    let idA = UUID()
    let idB = UUID()
    let systemFields = Data([0xCA, 0xFE, 0xBA, 0xBE])
    let profileA = ProfileRecord(
      id: idA,
      label: "Personal",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    profileA.encodedSystemFields = systemFields
    let profileB = ProfileRecord(
      id: idB,
      label: "Business",
      currencyCode: "USD",
      financialYearStartMonth: 1,
      createdAt: Date(timeIntervalSince1970: 1_700_100_000))
    // profileB.encodedSystemFields stays nil — both branches must copy
    // verbatim.
    context.insert(profileA)
    context.insert(profileB)
    try context.save()

    let defaults = makeIsolatedDefaults()
    let migrator = SwiftDataToGRDBMigrator()
    try await migrator.migrateProfileIndexIfNeeded(
      indexContainer: container,
      profileIndexDatabase: database,
      defaults: defaults)

    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.profileIndexFlag))

    let rows = try await database.read { database in
      try ProfileRow.fetchAll(database).sorted(by: { $0.createdAt < $1.createdAt })
    }
    #expect(rows.count == 2)
    let rowA = try #require(rows.first(where: { $0.id == idA }))
    #expect(rowA.recordName == "ProfileRecord|\(idA.uuidString)")
    #expect(rowA.label == "Personal")
    #expect(rowA.currencyCode == "AUD")
    #expect(rowA.financialYearStartMonth == 7)
    #expect(rowA.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(rowA.encodedSystemFields == systemFields)

    let rowB = try #require(rows.first(where: { $0.id == idB }))
    #expect(rowB.recordName == "ProfileRecord|\(idB.uuidString)")
    #expect(rowB.label == "Business")
    #expect(rowB.currencyCode == "USD")
    #expect(rowB.financialYearStartMonth == 1)
    #expect(rowB.createdAt == Date(timeIntervalSince1970: 1_700_100_000))
    #expect(rowB.encodedSystemFields == nil)
  }

  // MARK: - Idempotency

  @Test("re-running the migrator is a no-op once the flag is set")
  func reRunIsNoOp() async throws {
    let container = try makeIndexContainer()
    let database = try ProfileIndexDatabase.openInMemory()
    let context = ModelContext(container)
    let original = ProfileRecord(
      id: UUID(),
      label: "Personal",
      currencyCode: "AUD")
    context.insert(original)
    try context.save()

    let defaults = makeIsolatedDefaults()
    let migrator = SwiftDataToGRDBMigrator()
    try await migrator.migrateProfileIndexIfNeeded(
      indexContainer: container,
      profileIndexDatabase: database,
      defaults: defaults)

    // Add a row to SwiftData after the flag is set: a true no-op should
    // leave the GRDB table untouched.
    let extra = ProfileRecord(
      id: UUID(),
      label: "Business",
      currencyCode: "USD")
    context.insert(extra)
    try context.save()

    try await migrator.migrateProfileIndexIfNeeded(
      indexContainer: container,
      profileIndexDatabase: database,
      defaults: defaults)

    let count = try await database.read { database in
      try ProfileRow.fetchCount(database)
    }
    #expect(count == 1, "Second run must not double-insert nor pick up new SwiftData rows")
  }

  // MARK: - Failure path
  //
  // Mirrors the failure-path tests in `SwiftDataToGRDBMigratorTests` —
  // forces the GRDB write to throw and asserts the `committed` defer
  // flag invariant: the `UserDefaults` flag must NOT be set when the
  // write fails, so the next launch retries the migration.

  @Test("GRDB write failure leaves the flag unset for retry")
  func profileIndexMigrationFailureKeepsFlagUnset() async throws {
    let container = try makeIndexContainer()
    let database = try ProfileIndexDatabase.openInMemory()
    let context = ModelContext(container)
    let profile = ProfileRecord(
      id: UUID(),
      label: "Personal",
      currencyCode: "AUD",
      financialYearStartMonth: 7)
    context.insert(profile)
    try context.save()

    // Force the insert inside `migrateProfileIndexIfNeeded` to fail by
    // installing a BEFORE-INSERT trigger that aborts. `RAISE(ABORT, ...)`
    // propagates as a thrown error even with `onConflict: .ignore`
    // (IGNORE suppresses conflict-resolution errors, not RAISE(ABORT)).
    // The migrator's `committed = true` line runs *after* the write block;
    // if the write throws, the flag must stay false.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER abort_profile_migration
          BEFORE INSERT ON profile
          BEGIN SELECT RAISE(ABORT, 'forced'); END;
          """)
    }

    let defaults = makeIsolatedDefaults()
    let migrator = SwiftDataToGRDBMigrator()
    await #expect(throws: (any Error).self) {
      try await migrator.migrateProfileIndexIfNeeded(
        indexContainer: container,
        profileIndexDatabase: database,
        defaults: defaults)
    }
    #expect(
      !defaults.bool(forKey: SwiftDataToGRDBMigrator.profileIndexFlag),
      "Flag must remain false so the next launch retries")
    let rowCount = try await database.read { database in
      try ProfileRow.fetchCount(database)
    }
    #expect(rowCount == 0, "Failed write must leave the GRDB table empty")
  }

  // MARK: - Empty source

  @Test("empty SwiftData container produces empty GRDB and sets the flag")
  func emptySourceSetsFlag() async throws {
    let container = try makeIndexContainer()
    let database = try ProfileIndexDatabase.openInMemory()
    let defaults = makeIsolatedDefaults()
    let migrator = SwiftDataToGRDBMigrator()
    try await migrator.migrateProfileIndexIfNeeded(
      indexContainer: container,
      profileIndexDatabase: database,
      defaults: defaults)

    let count = try await database.read { database in
      try ProfileRow.fetchCount(database)
    }
    #expect(count == 0)
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.profileIndexFlag))
  }
}
