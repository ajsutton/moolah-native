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
/// A separate file (rather than a table inside `data.sqlite`) is
/// justified because the index has a materially different lifetime than
/// per-profile data: it must be readable before any profile is
/// activated, it survives every profile delete, and its access pattern
/// (one read at launch, occasional writes when profiles change) does
/// not benefit from sharing the per-profile WAL.
///
/// Migration history:
/// `v1_initial`                    — the `profile` table.
/// `v2_data_format_version`        — adds `data_format_version INTEGER NOT NULL DEFAULT 0`.
/// `v3_shared_instrument_registry` — adds the shared `instrument` table
///   (mirrors the per-profile post-v8 shape) plus the six rate-cache
///   tables — moved here from per-profile so spam decisions,
///   discovered-token resolutions, and price-cache rows propagate
///   across every profile on the same iCloud account. See
///   `ProfileIndexSchema+SharedInstrumentRegistry.swift`.
///
/// Each migration body is registered here. Once shipped, migration IDs
/// are frozen forever; splitting later is fine, merging post-ship is
/// not. As the schema grows, future migration bodies will move into
/// sibling `ProfileIndexSchema+<Name>.swift` extension files — matching
/// the convention `ProfileSchema` evolved into — so this file stays a
/// small index of registered migrations.
///
/// See `guides/DATABASE_SCHEMA_GUIDE.md` for the rules this schema
/// follows.
enum ProfileIndexSchema {
  /// Bumped each time a migration is added. Surfaced for open-time
  /// integrity checks; not used by `DatabaseMigrator` (which keys on
  /// the stable string IDs of registered migrations).
  static let version = 3

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()

    #if DEBUG
      migrator.eraseDatabaseOnSchemaChange = true
    #endif

    migrator.registerMigration("v1_initial", migrate: createProfileTable)
    migrator.registerMigration(
      "v2_data_format_version", migrate: addDataFormatVersionColumn)
    migrator.registerMigration(
      "v3_shared_instrument_registry",
      migrate: createSharedInstrumentRegistryTables)

    return migrator
  }

  private static func createProfileTable(_ database: Database) throws {
    try database.execute(
      sql: """
        -- WITHOUT ROWID: not used; encoded_system_fields BLOB dominates
        -- row size, which makes WITHOUT ROWID's interior-page packing a
        -- net loss (per `guides/DATABASE_SCHEMA_GUIDE.md` §3 decision
        -- table).
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

  private static func addDataFormatVersionColumn(_ database: Database) throws {
    try database.execute(
      sql: """
        ALTER TABLE profile
          ADD COLUMN data_format_version INTEGER NOT NULL DEFAULT 0;
        """)
  }
}
