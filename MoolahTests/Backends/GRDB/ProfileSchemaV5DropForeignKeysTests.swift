// MoolahTests/Backends/GRDB/ProfileSchemaV5DropForeignKeysTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileSchema v5 drops foreign keys")
struct ProfileSchemaV5DropForeignKeysTests {
  /// After every migration including v5 has run, none of the four child
  /// tables list any FKs in `pragma_foreign_key_list`. This is the
  /// schema-side contract the rest of the work depends on.
  @Test
  func childTablesHaveNoForeignKeys() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.read { database in
      for table in ["category", "earmark_budget_item", "transaction_leg", "investment_value"] {
        let fks = try Row.fetchAll(
          database, sql: "SELECT * FROM pragma_foreign_key_list(?)", arguments: [table])
        #expect(fks.isEmpty, "Expected no FKs on \(table); got \(fks)")
      }
    }
  }
}
