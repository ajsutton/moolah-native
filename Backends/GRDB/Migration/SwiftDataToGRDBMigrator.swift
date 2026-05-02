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
/// commits. The write path uses `insert(onConflict: .ignore)` so that
/// a crash *between* the transaction commit and the `defaults.set(...)`
/// call (the unavoidable gap) re-running on next launch is harmless —
/// insert-or-ignore silently skips already-present rows. Critically,
/// insert-or-ignore also preserves any row written by sync apply
/// *before* the migrator runs: a sync-applied row represents a
/// server-authoritative version and must never be clobbered by an
/// older SwiftData copy. A `defer { committed ? flag = true : () }`
/// pattern makes the flag-set-on-success invariant structurally visible.
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
/// **Concurrency.** The struct is `@MainActor`-isolated because the
/// SwiftData fetches need `@MainActor` (`ModelContext(modelContainer)`
/// and `context.fetch(...)` are main-actor-isolated when the container
/// is `mainContext`-bound). Every public method is `async throws` so
/// the heavy GRDB write can be dispatched onto GRDB's own writer queue
/// via `await database.write { ... }` — that hop moves the eight v3
/// core-financial-graph upserts (which can push past one frame on
/// heavy stores) off the main thread while the bounded SwiftData
/// fetches stay on `@MainActor` (where the SwiftData container
/// requires them). Issue #575 tracked this conversion.
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

  /// All `UserDefaults` keys that gate this migrator. Used by
  /// `resetMigrationFlags(in:)` to reset state between UI test launches —
  /// each test launches a fresh in-memory `ProfileContainerManager` with
  /// new seed data, but `UserDefaults.standard` persists across xctest
  /// launches in the same runner. Without resetting, the second test's
  /// migrator would skip and the seeded SwiftData rows would never reach
  /// GRDB. Production launches never call this reset.
  static let allMigrationFlags: [String] = [
    csvImportProfilesFlag,
    importRulesFlag,
    instrumentsFlag,
    categoriesFlag,
    accountsFlag,
    earmarksFlag,
    earmarkBudgetItemsFlag,
    investmentValuesFlag,
    transactionsFlag,
    transactionLegsFlag,
    profileIndexFlag,
  ]

  /// Clears every gating flag set by `migrateIfNeeded` so the next call
  /// re-runs the full SwiftData → GRDB copy. Intended for `--ui-testing`
  /// launches only: each UI test starts from a fresh in-memory profile
  /// container and must observe its own seeded rows in GRDB. No
  /// production code path should invoke this.
  static func resetMigrationFlags(in defaults: UserDefaults = .standard) {
    for key in allMigrationFlags {
      defaults.removeObject(forKey: key)
    }
  }

  let logger = Logger(
    subsystem: "com.moolah.app", category: "SwiftDataToGRDBMigrator")

  /// Runs the one-shot migration for every record type. Each is gated
  /// independently; a previously-migrated record type is a no-op.
  ///
  /// `defaults` is injected with a `.standard` default so production
  /// callers pass nothing while tests supply an isolated suite (avoids
  /// the `CODE_GUIDE.md` §17 "no direct singleton access" rule).
  ///
  /// `async throws` because each per-type migrator awaits
  /// `database.write { ... }` to push the GRDB transaction onto GRDB's
  /// own writer queue (off-MainActor) instead of holding the calling
  /// thread for the duration of the insert. The bounded SwiftData
  /// fetch stays on `@MainActor` (where the `mainContext`-bound
  /// container requires it). Total work is bounded by the row counts
  /// in the source SwiftData store. The eight v3 migrators run in
  /// parents-before-children order so foreign-key references resolve
  /// as each transaction commits.
  func migrateIfNeeded(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    defaults: UserDefaults = .standard
  ) async throws {
    let start = ContinuousClock.now
    defer {
      let elapsedMs = (ContinuousClock.now - start).inMilliseconds
      // 16ms ≈ one frame at 60Hz. The async migrator no longer pins
      // the calling actor for the duration of the GRDB write, so this
      // warning is now a wall-clock signal: if the elapsed time
      // exceeds a frame and the caller was @MainActor, scrolling /
      // animations on the main thread were still potentially impacted
      // by the bounded SwiftData fetch. Logged in release as well as
      // debug so production diagnostics surface real-world durations
      // on heavy users.
      if elapsedMs > 16 {
        logger.warning(
          """
          SwiftDataToGRDBMigrator.migrateIfNeeded took \(elapsedMs, privacy: .public)ms; \
          GRDB writes ran off-actor but the bounded SwiftData fetches still hopped to \
          @MainActor — investigate if this reproduces on real hardware.
          """)
      }
    }
    // Core financial graph — parents before children so each
    // transaction's FK references resolve at commit. PRAGMA
    // foreign_keys = ON is in effect; an unresolved parent fails the
    // insert loudly, which is the correct behaviour.
    try await migrateInstrumentsIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try await migrateCategoriesIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try await migrateAccountsIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try await migrateEarmarksIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try await migrateEarmarkBudgetItemsIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try await migrateInvestmentValuesIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try await migrateTransactionsIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try await migrateTransactionLegsIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    // CSV imports reference accounts; run them after the core graph
    // so any FK validation at the application layer sees a populated
    // `account` table.
    try await migrateCSVImportProfilesIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
    try await migrateImportRulesIfNeeded(
      modelContainer: modelContainer, database: database, defaults: defaults)
  }

  // MARK: - CSV import profiles

  private func migrateCSVImportProfilesIfNeeded(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    defaults: UserDefaults
  ) async throws {
    guard !defaults.bool(forKey: Self.csvImportProfilesFlag) else { return }
    // The `committed` flag is flipped after the write transaction commits
    // and consulted by the `defer` block — making the
    // "flag is set iff the write committed" invariant visible without
    // duplicating the success path. `insert(onConflict: .ignore)` keeps
    // re-runs harmless if the app crashes between commit and flag-set,
    // and also preserves any sync-applied row that already exists in GRDB
    // so it is not clobbered by an older SwiftData copy.
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
    let mappedRows = try Self.fetchSwiftDataRows(
      modelContainer: modelContainer,
      recordTypeDescription: "CSVImportProfileRecord",
      type: CSVImportProfileRecord.self,
      mapper: Self.mapCSVProfile(_:),
      logger: logger)
    if !mappedRows.isEmpty {
      try await database.write { database in
        for row in mappedRows {
          try row.insert(database, onConflict: .ignore)
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
  ) async throws {
    guard !defaults.bool(forKey: Self.importRulesFlag) else { return }
    // See `migrateCSVImportProfilesIfNeeded` for why this uses a
    // `committed` defer flag and `insert(onConflict: .ignore)`
    // (idempotent re-migration; preserves sync-applied rows).
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
    let mappedRows = try Self.fetchSwiftDataRows(
      modelContainer: modelContainer,
      recordTypeDescription: "ImportRuleRecord",
      type: ImportRuleRecord.self,
      mapper: Self.mapImportRule(_:),
      logger: logger)
    if !mappedRows.isEmpty {
      try await database.write { database in
        for row in mappedRows {
          try row.insert(database, onConflict: .ignore)
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

  // MARK: - SwiftData fetch helper

  /// Fetches every persisted instance of `Source` from `modelContainer`
  /// and maps them into the GRDB row type `Mapped`. Stays on
  /// `@MainActor` (inherited from the enclosing struct) because
  /// `ModelContext(_:)` and `context.fetch(_:)` are
  /// `@MainActor`-isolated when the container is the app's
  /// `mainContext`. The returned array is `Sendable` (each element is a
  /// `Sendable` GRDB row), so the calling `async` method can hand it
  /// off to `await database.write { ... }` and that write runs
  /// off-MainActor.
  ///
  /// Failures are logged at error level then re-thrown so per-type
  /// migrators can record their own context-specific message and the
  /// `defer { committed ? flag = true : () }` invariant continues to
  /// hold (the flag is only set when the function exits via the
  /// `committed = true` path).
  static func fetchSwiftDataRows<Source: PersistentModel, Mapped: Sendable>(
    modelContainer: ModelContainer,
    recordTypeDescription: String,
    type: Source.Type,
    mapper: (Source) -> Mapped,
    logger: Logger
  ) throws -> [Mapped] {
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<Source>()
    let sourceRows: [Source]
    do {
      sourceRows = try context.fetch(descriptor)
    } catch {
      logger.error(
        """
        SwiftData fetch for \(recordTypeDescription, privacy: .public) failed during \
        GRDB migration: \(error.localizedDescription, privacy: .public). Migration \
        aborted; will retry next launch.
        """)
      throw error
    }
    return sourceRows.map(mapper)
  }
}
