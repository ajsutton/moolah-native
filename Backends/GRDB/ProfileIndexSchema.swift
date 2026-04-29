// Backends/GRDB/ProfileIndexSchema.swift

import Foundation
import GRDB

/// Schema definition for the app-scoped `profile-index.sqlite`.
///
/// One database per app install. Holds one row per CloudKit profile so
/// the profile picker can list profiles before any of them is
/// activated. Independent of any per-profile `data.sqlite` — no FKs in
/// or out.
///
/// Migration history:
/// `v1_initial` — the `profile` table.
///
/// Each migration body is registered here. Once shipped, migration IDs
/// are frozen forever; splitting later is fine, merging post-ship is
/// not.
///
/// See `guides/DATABASE_SCHEMA_GUIDE.md` for the rules this schema
/// follows.
enum ProfileIndexSchema {
  /// Bumped each time a migration is added. Surfaced for open-time
  /// integrity checks; not used by `DatabaseMigrator` (which keys on
  /// the stable string IDs of registered migrations).
  static let version = 1

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()

    #if DEBUG
      migrator.eraseDatabaseOnSchemaChange = true
    #endif

    migrator.registerMigration("v1_initial", migrate: createProfileTable)

    return migrator
  }

  private static func createProfileTable(_ database: Database) throws {
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

        -- Drives `loadCloudProfiles`'s SortDescriptor(\\.createdAt).
        CREATE INDEX profile_by_created_at ON profile(created_at);
        """)
  }
}
