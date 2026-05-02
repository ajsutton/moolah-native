// MoolahTests/Sync/SwiftDataToGRDBMigratorPreserveTests.swift

import Foundation
import GRDB
import SwiftData
import Testing

@testable import Moolah

@Suite("SwiftDataToGRDBMigrator — preserve")
@MainActor
struct SwiftDataToGRDBMigratorPreserveTests {

  private func makeIsolatedDefaults(suffix: String) -> UserDefaults {
    let suiteName = "com.moolah.migrator-preserve-tests.\(suffix)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  /// Per-type pinned: the migrator does not overwrite a GRDB row that
  /// sync wrote first (newer truth). The flag still latches.
  @Test("migrator does not clobber a GRDB row that already exists")
  func migratorPreservesExistingGRDBRow() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let defaults = makeIsolatedDefaults(suffix: UUID().uuidString)

    // Seed SwiftData with one CategoryRecord.
    let context = ModelContext(container)
    let categoryId = UUID()
    let swiftDataRecord = CategoryRecord(
      id: categoryId,
      name: "From SwiftData",
      parentId: nil)
    swiftDataRecord.encodedSystemFields = Data([0x01, 0x02, 0x03])
    context.insert(swiftDataRecord)
    try context.save()

    // Pre-seed GRDB with a *different* row for the same id (simulating
    // the sync-applied row).
    try await database.write { writer in
      try CategoryRow(
        id: categoryId,
        recordName: CategoryRow.recordName(for: categoryId),
        name: "From CloudKit",
        parentId: nil,
        encodedSystemFields: Data([0xAA, 0xBB, 0xCC])
      ).insert(writer)
    }

    try await SwiftDataToGRDBMigrator().migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)

    let stored = try await database.read { reader in
      try CategoryRow.filter(CategoryRow.Columns.id == categoryId).fetchOne(reader)
    }
    #expect(stored?.name == "From CloudKit")
    #expect(stored?.encodedSystemFields == Data([0xAA, 0xBB, 0xCC]))
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.categoriesFlag))
  }

  /// Sanity: empty GRDB still gets seeded from SwiftData.
  @Test("migrator still seeds empty GRDB tables")
  func migratorSeedsEmptyGRDB() async throws {
    let container = try TestModelContainer.create()
    let database = try ProfileDatabase.openInMemory()
    let defaults = makeIsolatedDefaults(suffix: UUID().uuidString)

    let context = ModelContext(container)
    let categoryId = UUID()
    let record = CategoryRecord(id: categoryId, name: "Seed me", parentId: nil)
    record.encodedSystemFields = Data()
    context.insert(record)
    try context.save()

    try await SwiftDataToGRDBMigrator().migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)

    let stored = try await database.read { reader in
      try CategoryRow.filter(CategoryRow.Columns.id == categoryId).fetchOne(reader)
    }
    #expect(stored?.name == "Seed me")
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.categoriesFlag))
  }
}
