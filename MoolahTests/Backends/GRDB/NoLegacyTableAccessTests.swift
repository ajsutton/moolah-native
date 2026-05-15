// MoolahTests/Backends/GRDB/NoLegacyTableAccessTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Documents the contract that a fully-migrated per-profile
/// `data.sqlite` does not carry the legacy instrument / market-data
/// tables, so any code that tries to read them fails loudly at the
/// SQLite layer rather than silently seeing an empty result. The
/// authoritative instrument registry is the shared profile-index DB;
/// the price caches are network-derived and also live on the shared DB.
@Suite("Legacy per-profile tables are inaccessible after v10")
struct NoLegacyTableAccessTests {
  @Test
  func selectFromDroppedInstrumentTableThrows() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    #expect(throws: DatabaseError.self) {
      try queue.read { database in
        _ = try Int.fetchOne(database, sql: "SELECT 1 FROM instrument")
      }
    }
  }

  @Test
  func selectFromDroppedPriceCacheTableThrows() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    #expect(throws: DatabaseError.self) {
      try queue.read { database in
        _ = try Int.fetchOne(database, sql: "SELECT 1 FROM crypto_price")
      }
    }
  }
}
