import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileIndexSchema — v2_data_format_version")
struct ProfileIndexSchemaV2Tests {
  private func makeMigratedDatabase() throws -> DatabaseQueue {
    // Match production: pragma config + migrator both via the project factory.
    try ProfileIndexDatabase.openInMemory()
  }

  @Test("schema version reflects the v2 migration")
  func versionIsTwo() {
    #expect(ProfileIndexSchema.version == 2)
  }

  @Test("v2 migration adds the data_format_version column with default 0")
  func columnExistsWithDefaultZero() throws {
    let queue = try makeMigratedDatabase()
    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO profile (id, record_name, label, currency_code,
            financial_year_start_month, created_at)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          UUID(), "ProfileRecord|abc", "Test", "AUD", 7, Date(),
        ])
      let value = try Int.fetchOne(
        database, sql: "SELECT data_format_version FROM profile LIMIT 1")
      #expect(value == 0)
    }
  }

  @Test("inserted rows default data_format_version to 0 — post-migration default")
  func insertedRowsDefaultToZero() throws {
    let queue = try makeMigratedDatabase()
    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO profile (id, record_name, label, currency_code,
            financial_year_start_month, created_at)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          UUID(), "ProfileRecord|legacy", "Legacy", "AUD", 7, Date(),
        ])
      let value = try Int.fetchOne(
        database, sql: "SELECT data_format_version FROM profile LIMIT 1")
      #expect(value == 0)
    }
  }

  @Test("ALTER TABLE backfills pre-existing rows to data_format_version = 0")
  func alterTableBackfillsExistingRowsToZero() throws {
    // True backfill test: insert a row under v1-only schema, then run
    // v2's ALTER TABLE, then read the column. This exercises SQLite's
    // ADD COLUMN ... DEFAULT 0 backfill semantic for existing rows
    // (different from the post-migration INSERT path covered above).
    // Implemented via a pair of explicit DatabaseMigrator instances —
    // value types, no factory internals required.
    let queue = try DatabaseQueue()
    var v1Migrator = DatabaseMigrator()
    v1Migrator.registerMigration("v1_initial") { database in
      try database.execute(
        sql: """
          CREATE TABLE profile (
              id                          BLOB    NOT NULL PRIMARY KEY,
              record_name                 TEXT    NOT NULL UNIQUE,
              label                       TEXT    NOT NULL,
              currency_code               TEXT    NOT NULL,
              financial_year_start_month  INTEGER NOT NULL
                  CHECK (financial_year_start_month BETWEEN 1 AND 12),
              created_at                  TEXT    NOT NULL,
              encoded_system_fields       BLOB
          ) STRICT;
          """)
    }
    try v1Migrator.migrate(queue)

    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO profile (id, record_name, label, currency_code,
            financial_year_start_month, created_at)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          UUID(), "ProfileRecord|legacy", "Legacy", "AUD", 7, Date(),
        ])
    }

    var v2Migrator = DatabaseMigrator()
    v2Migrator.registerMigration("v1_initial") { _ in /* already applied */ }
    v2Migrator.registerMigration("v2_data_format_version") { database in
      try database.execute(
        sql: """
          ALTER TABLE profile
            ADD COLUMN data_format_version INTEGER NOT NULL DEFAULT 0;
          """)
    }
    try v2Migrator.migrate(queue)

    try queue.read { database in
      let value = try Int.fetchOne(
        database, sql: "SELECT data_format_version FROM profile LIMIT 1")
      #expect(value == 0)
    }
  }
}
