// Backends/GRDB/ProfileSchema+CSVImportAndRules.swift

import Foundation
import GRDB

// MARK: - v2 migration body
//
// Both tables hold synced user data, so each one carries
// `encoded_system_fields BLOB` (the cached CKRecord change tag) and
// `record_name TEXT NOT NULL UNIQUE` (the canonical CloudKit
// recordName, e.g. `"CSVImportProfileRecord|<uuid>"`). ROWID is kept
// (single-column UUID PK + wide rows — `WITHOUT ROWID` is not
// justified per `DATABASE_SCHEMA_GUIDE.md` §3).

extension ProfileSchema {
  static func createCSVImportAndRulesTables(_ database: Database) throws {
    try createCSVImportProfileTable(database)
    try createImportRuleTable(database)
  }

  // CHECK constraints below pin the SQL-side invariants per
  // `DATABASE_SCHEMA_GUIDE.md` §3:
  //   * Booleans on Bool-typed columns are restricted to 0/1.
  //   * `match_mode` is restricted to the `MatchMode` raw values
  //     (`"any"` / `"all"`). Verified against
  //     `Domain/Models/CSVImport/ImportRule.swift` — change in lock-step
  //     if the enum's raw values ever diverge.
  //   * `position` is non-negative; `reorder` always produces 0…n-1.

  private static func createCSVImportProfileTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE csv_import_profile (
            id                              BLOB    NOT NULL PRIMARY KEY,
            record_name                     TEXT    NOT NULL UNIQUE,
            -- No REFERENCES clause: this table predates the `account`
            -- table in the migration history. Referential integrity is
            -- enforced at the application layer; SQLite's table-rebuild
            -- pattern can add the REFERENCES later if desired.
            account_id                      BLOB    NOT NULL,
            parser_identifier               TEXT    NOT NULL,
            header_signature                TEXT    NOT NULL,
            filename_pattern                TEXT,
            delete_after_import             INTEGER NOT NULL
                CHECK (delete_after_import IN (0, 1)),
            created_at                      TEXT    NOT NULL,
            last_used_at                    TEXT,
            date_format_raw_value           TEXT,
            column_role_raw_values_encoded  TEXT,
            encoded_system_fields           BLOB
        ) STRICT;

        -- account_id FK child index (`fetchByAccount`-style filters).
        CREATE INDEX csv_import_profile_account
            ON csv_import_profile(account_id);
        -- Covers `fetchAll().order(created_at)` in
        -- `GRDBCSVImportProfileRepository.fetchAll`.
        CREATE INDEX csv_import_profile_created
            ON csv_import_profile(created_at);
        """)
  }

  private static func createImportRuleTable(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE import_rule (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            name                   TEXT    NOT NULL,
            enabled                INTEGER NOT NULL
                CHECK (enabled IN (0, 1)),
            position               INTEGER NOT NULL
                CHECK (position >= 0),
            match_mode             TEXT    NOT NULL
                CHECK (match_mode IN ('all', 'any')),
            conditions_json        BLOB    NOT NULL,
            actions_json           BLOB    NOT NULL,
            account_scope          BLOB,
            encoded_system_fields  BLOB
        ) STRICT;

        CREATE INDEX import_rule_position
            ON import_rule(position);
        CREATE INDEX import_rule_account_scope
            ON import_rule(account_scope) WHERE account_scope IS NOT NULL;
        """)
  }
}
