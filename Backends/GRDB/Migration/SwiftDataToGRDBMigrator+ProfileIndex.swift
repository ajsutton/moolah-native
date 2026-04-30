// Backends/GRDB/Migration/SwiftDataToGRDBMigrator+ProfileIndex.swift

import Foundation
import GRDB
import OSLog
import SwiftData

// One-shot SwiftData → GRDB migrator for the app-scoped profile index.
//
// Sibling per-type migrators (CSV import, import rules, core financial
// graph, earmarks, transactions) live alongside their per-profile
// `data.sqlite` write target and run inside
// `migrateIfNeeded(modelContainer:database:defaults:)`. The profile
// index is **app-scoped** — one DB per install, independent of any
// profile session — so its migrator has a different hook point and
// different inputs (the index `ModelContainer` and the
// `profile-index.sqlite` writer). Task 5 wires the call site at app
// launch; this extension just exposes the entry point.

extension SwiftDataToGRDBMigrator {

  /// `UserDefaults` key gating the profile-index copy. Once true, the
  /// migrator skips this record type for the install's lifetime.
  static let profileIndexFlag = "v4.profileIndex.grdbMigrated"

  /// Migrates `ProfileRecord` rows from the SwiftData index container
  /// into the GRDB `profile-index.sqlite`.
  ///
  /// The destination is app-scoped (not per-profile), so this migrator
  /// has its own entry point — it is **not** invoked from
  /// `migrateIfNeeded(modelContainer:database:defaults:)` (which
  /// orchestrates the per-profile migrators against a profile's
  /// `data.sqlite`). Task 5 calls this once at app launch.
  ///
  /// The `committed` defer pattern matches the per-profile migrators:
  /// the gating flag is set only after the GRDB transaction commits,
  /// and `upsert` (rather than `insert`) keeps a re-run after a crash
  /// between commit and flag-set harmless.
  ///
  /// `encodedSystemFields` is copied byte-for-byte. Decoding it would
  /// lose precision (the `NSKeyedArchiver` round-trip is not guaranteed
  /// identical) and trip a `.serverRecordChanged` cycle on the first
  /// sync after migration.
  func migrateProfileIndexIfNeeded(
    indexContainer: ModelContainer,
    profileIndexDatabase: any DatabaseWriter,
    defaults: UserDefaults
  ) async throws {
    guard !defaults.bool(forKey: Self.profileIndexFlag) else { return }
    var committed = false
    var rowCount = 0
    defer {
      if committed {
        defaults.set(true, forKey: Self.profileIndexFlag)
        logger.info(
          """
          SwiftData → GRDB migration complete for ProfileRecord: \
          \(rowCount, privacy: .public) row(s) copied
          """)
      }
    }
    let mappedRows = try Self.fetchSwiftDataRows(
      modelContainer: indexContainer,
      recordTypeDescription: "ProfileRecord",
      type: ProfileRecord.self,
      mapper: Self.mapProfile(_:),
      logger: logger)
    if !mappedRows.isEmpty {
      try await profileIndexDatabase.write { database in
        for row in mappedRows {
          try row.upsert(database)
        }
      }
    }
    rowCount = mappedRows.count
    committed = true
  }

  /// Maps a SwiftData `ProfileRecord` to a `ProfileRow`, preserving
  /// `encodedSystemFields` byte-for-byte and re-deriving `record_name`
  /// from the canonical CloudKit recordName format.
  private static func mapProfile(_ source: ProfileRecord) -> ProfileRow {
    ProfileRow(
      id: source.id,
      recordName: ProfileRow.recordName(for: source.id),
      label: source.label,
      currencyCode: source.currencyCode,
      financialYearStartMonth: source.financialYearStartMonth,
      createdAt: source.createdAt,
      encodedSystemFields: source.encodedSystemFields)
  }
}
