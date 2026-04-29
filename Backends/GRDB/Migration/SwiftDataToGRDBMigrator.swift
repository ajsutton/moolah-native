// Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift

import Foundation
import GRDB
import OSLog
import SwiftData

/// One-shot migrator that copies the synced SwiftData record types into
/// a profile's GRDB `data.sqlite`. Each record type is gated by an
/// independent `UserDefaults` flag so a partial migration never
/// re-runs against an already-populated table.
///
/// **Idempotency.** Set the flag *only* after the GRDB transaction
/// commits. The write path uses `upsert` rather than `insert` so a
/// crash *between* the transaction commit and the `defaults.set(...)`
/// call (the unavoidable gap) re-running on next launch is harmless —
/// the upsert no-ops on already-present rows. A `defer { committed ?
/// flag = true : () }` pattern makes the flag-set-on-success invariant
/// structurally visible.
///
/// **Bit-for-bit `encodedSystemFields`.** The migrator copies the cached
/// CKRecord change-tag blob byte-for-byte from the SwiftData row to the
/// GRDB row. Decoding it would lose precision (the round-trip of
/// `NSKeyedArchiver` outputs is not guaranteed identical) and trip a
/// `.serverRecordChanged` cycle on the first sync after migration.
///
/// **Hook point.** Called from `MoolahApp+Setup` after every active
/// `ProfileSession` has been opened and before
/// `SyncCoordinator.start()` so CKSyncEngine reads from a fully
/// populated `data.sqlite` on the first launch.
///
/// **Concurrency.** `@MainActor` is required because the SwiftData
/// `ModelContext(modelContainer)` constructor and the resulting
/// `context.fetch(...)` are `@MainActor`-isolated when the container is
/// `mainContext`-bound. The GRDB writes themselves are queue-serialised
/// and don't need main-actor isolation. If profiling ever shows this
/// blocks for >16ms (one frame) on a p99 device, convert
/// `migrateIfNeeded` to async and call with `await` from
/// `ProfileSession.init` (per `guides/CONCURRENCY_GUIDE.md` §1).
@MainActor
struct SwiftDataToGRDBMigrator {
  /// `UserDefaults` key gating the CSV-import-profile copy. Once true,
  /// the migrator skips this record type for the install's lifetime.
  static let csvImportProfilesFlag = "v2.csvImportProfiles.grdbMigrated"
  /// `UserDefaults` key gating the import-rule copy.
  static let importRulesFlag = "v2.importRules.grdbMigrated"
  // Core financial graph flags (v3 schema). Each table gets its own
  // flag so a partial migration of the eight types never re-runs
  // against an already-populated table.
  static let instrumentsFlag = "v3.instruments.grdbMigrated"
  static let categoriesFlag = "v3.categories.grdbMigrated"
  static let accountsFlag = "v3.accounts.grdbMigrated"
  static let earmarksFlag = "v3.earmarks.grdbMigrated"
  static let earmarkBudgetItemsFlag = "v3.earmarkBudgetItems.grdbMigrated"
  static let investmentValuesFlag = "v3.investmentValues.grdbMigrated"
  static let transactionsFlag = "v3.transactions.grdbMigrated"
  static let transactionLegsFlag = "v3.transactionLegs.grdbMigrated"

  let logger = Logger(
    subsystem: "com.moolah.app", category: "SwiftDataToGRDBMigrator")

  /// Runs the one-shot migration for every record type. Each is gated
  /// independently; a previously-migrated record type is a no-op.
  ///
  /// `defaults` is injected with a `.standard` default so production
  /// callers pass nothing while tests supply an isolated suite (avoids
  /// the `CODE_GUIDE.md` §17 "no direct singleton access" rule).
  ///
  /// Synchronous because the only places it runs (per-profile session
  /// init and seed tests) need to block the calling thread until both
  /// SwiftData reads and GRDB writes complete. Total work is bounded
  /// by the row counts in the source SwiftData store. The eight v3
  /// migrators run in parents-before-children order so foreign-key
  /// references resolve as each transaction commits.
  func migrateIfNeeded(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    defaults: UserDefaults = .standard
  ) throws {
    let start = ContinuousClock.now
    defer {
      let elapsedMs = (ContinuousClock.now - start).inMilliseconds
      // 16ms ≈ one frame at 60Hz. Sync migrator runs on @MainActor, so
      // exceeding this budget means we're hanging the UI on a slow
      // device. Log in release as well as debug so production
      // diagnostics surface real-world durations on heavy users —
      // tracked via the `os_log` warning channel (subsystem
      // `com.moolah.app`, category `SwiftDataToGRDBMigrator`).
      // Intentional signal-only check, not a hard precondition; the
      // migration's correctness is independent of how long it takes.
      // The v3 core-financial-graph migrators may push past 16ms on
      // heavy stores (eight transactions × N rows each); the warning
      // is signal-only and intentionally not bumped.
      if elapsedMs > 16 {
        logger.warning(
          """
          SwiftDataToGRDBMigrator.migrateIfNeeded took \(elapsedMs, privacy: .public)ms \
          on @MainActor; convert to async if this reproduces on real hardware (see \
          file header).
          """)
      }
    }
    // Core financial graph — parents before children so each
    // transaction's FK references resolve at commit. PRAGMA
    // foreign_keys = ON is in effect; an unresolved parent fails the
    // upsert loudly, which is the correct behaviour.
    try migrateInstrumentsIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try migrateCategoriesIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try migrateAccountsIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try migrateEarmarksIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try migrateEarmarkBudgetItemsIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try migrateInvestmentValuesIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try migrateTransactionsIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try migrateTransactionLegsIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    // CSV imports reference accounts; run them after the core graph
    // so any FK validation at the application layer sees a populated
    // `account` table.
    try migrateCSVImportProfilesIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try migrateImportRulesIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
  }

  // MARK: - CSV import profiles

  private func migrateCSVImportProfilesIfNeeded(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    defaults: UserDefaults
  ) throws {
    guard !defaults.bool(forKey: Self.csvImportProfilesFlag) else { return }
    // The `committed` flag is flipped after the write transaction commits
    // and consulted by the `defer` block — making the
    // "flag is set iff the write committed" invariant visible without
    // duplicating the success path. `upsert` (rather than `insert`)
    // keeps re-runs harmless if the app crashes between commit and
    // flag-set: existing rows are a no-op match.
    var committed = false
    var rowCount = 0
    defer {
      if committed {
        defaults.set(true, forKey: Self.csvImportProfilesFlag)
        logger.info(
          """
          SwiftData → GRDB migration complete for CSVImportProfile: \
          \(rowCount, privacy: .public) row(s) copied
          """)
      }
    }
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<CSVImportProfileRecord>()
    let sourceRows: [CSVImportProfileRecord]
    do {
      sourceRows = try context.fetch(descriptor)
    } catch {
      logger.error(
        """
        SwiftData fetch for CSVImportProfileRecord failed during GRDB \
        migration: \(error.localizedDescription, privacy: .public). \
        Migration aborted; will retry next launch.
        """)
      throw error
    }
    let mappedRows = sourceRows.map(Self.mapCSVProfile(_:))
    if !mappedRows.isEmpty {
      try database.write { database in
        for row in mappedRows {
          try row.upsert(database)
        }
      }
    }
    rowCount = mappedRows.count
    committed = true
  }

  /// Maps a SwiftData `CSVImportProfileRecord` to a `CSVImportProfileRow`,
  /// preserving `encodedSystemFields` byte-for-byte and re-deriving
  /// `record_name` from the canonical CloudKit recordName format.
  private static func mapCSVProfile(_ source: CSVImportProfileRecord) -> CSVImportProfileRow {
    CSVImportProfileRow(
      id: source.id,
      recordName: CSVImportProfileRow.recordName(for: source.id),
      accountId: source.accountId,
      parserIdentifier: source.parserIdentifier,
      headerSignature: source.headerSignature,
      filenamePattern: source.filenamePattern,
      deleteAfterImport: source.deleteAfterImport,
      createdAt: source.createdAt,
      lastUsedAt: source.lastUsedAt,
      dateFormatRawValue: source.dateFormatRawValue,
      columnRoleRawValuesEncoded: source.columnRoleRawValuesEncoded,
      encodedSystemFields: source.encodedSystemFields)
  }

  // MARK: - Import rules

  private func migrateImportRulesIfNeeded(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    defaults: UserDefaults
  ) throws {
    guard !defaults.bool(forKey: Self.importRulesFlag) else { return }
    // See `migrateCSVImportProfilesIfNeeded` for why this uses a
    // `committed` defer flag and `upsert` (idempotent re-migration).
    var committed = false
    var rowCount = 0
    defer {
      if committed {
        defaults.set(true, forKey: Self.importRulesFlag)
        logger.info(
          """
          SwiftData → GRDB migration complete for ImportRule: \
          \(rowCount, privacy: .public) row(s) copied
          """)
      }
    }
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<ImportRuleRecord>()
    let sourceRows: [ImportRuleRecord]
    do {
      sourceRows = try context.fetch(descriptor)
    } catch {
      logger.error(
        """
        SwiftData fetch for ImportRuleRecord failed during GRDB \
        migration: \(error.localizedDescription, privacy: .public). \
        Migration aborted; will retry next launch.
        """)
      throw error
    }
    let mappedRows = sourceRows.map(Self.mapImportRule(_:))
    if !mappedRows.isEmpty {
      try database.write { database in
        for row in mappedRows {
          try row.upsert(database)
        }
      }
    }
    rowCount = mappedRows.count
    committed = true
  }

  /// Maps a SwiftData `ImportRuleRecord` to an `ImportRuleRow`, preserving
  /// `encodedSystemFields` and the JSON blob bytes for conditions/actions
  /// byte-for-byte (no decode/encode cycle — see file header).
  private static func mapImportRule(_ source: ImportRuleRecord) -> ImportRuleRow {
    ImportRuleRow(
      id: source.id,
      recordName: ImportRuleRow.recordName(for: source.id),
      name: source.name,
      enabled: source.enabled,
      position: source.position,
      matchMode: source.matchMode,
      conditionsJSON: source.conditionsJSON,
      actionsJSON: source.actionsJSON,
      accountScope: source.accountScope,
      encodedSystemFields: source.encodedSystemFields)
  }
}
