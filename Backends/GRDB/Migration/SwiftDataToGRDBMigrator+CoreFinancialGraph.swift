// Backends/GRDB/Migration/SwiftDataToGRDBMigrator+CoreFinancialGraph.swift

import Foundation
import GRDB
import SwiftData

// Per-type SwiftData → GRDB migrators for the core financial graph
// (instrument, category, account, earmark, earmark_budget_item,
// investment_value, transaction, transaction_leg). One private function
// per type, each mirroring the established
// `migrateCSVImportProfilesIfNeeded` pattern: open a `ModelContext`,
// fetch all rows, map to the corresponding GRDB row, write inside one
// `database.write` transaction, then flip the `UserDefaults` flag in
// the `defer` block once `committed` is true. `insert(onConflict:
// .ignore)` keeps re-runs idempotent if the app crashes between commit
// and flag-set, and preserves sync-applied rows that arrived before
// the migrator ran.
//
// **Ordering.** Parents run before children so foreign-key references
// resolve at commit time. `transaction_leg.account_id` is
// `ON DELETE SET NULL` and nullable; we still migrate accounts before
// legs because every other FK on a leg (`transaction_id`,
// `category_id`, `earmark_id`) requires the parent row to exist.
//
// **Bit-for-bit `encodedSystemFields`.** The cached CKRecord
// change-tag blob is copied byte-for-byte. See the file header in
// `SwiftDataToGRDBMigrator.swift` for why we never decode it.

extension SwiftDataToGRDBMigrator {

  // MARK: - Instruments

  func migrateInstrumentsIfNeeded(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    defaults: UserDefaults
  ) async throws {
    guard !defaults.bool(forKey: Self.instrumentsFlag) else { return }
    var committed = false
    var rowCount = 0
    defer {
      if committed {
        defaults.set(true, forKey: Self.instrumentsFlag)
        logger.info(
          """
          SwiftData → GRDB migration complete for InstrumentRecord: \
          \(rowCount, privacy: .public) row(s) copied
          """)
      }
    }
    let mappedRows = try Self.fetchSwiftDataRows(
      modelContainer: modelContainer,
      recordTypeDescription: "InstrumentRecord",
      type: InstrumentRecord.self,
      mapper: Self.mapInstrument(_:),
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

  /// Maps a SwiftData `InstrumentRecord` to an `InstrumentRow`.
  /// `Instrument` is string-keyed; `recordName(for:)` returns the bare
  /// id. Provider-mapping fields (`coingeckoId`, `cryptocompareSymbol`,
  /// `binanceSymbol`) are copied verbatim — they live on the
  /// persistence side only.
  private static func mapInstrument(_ source: InstrumentRecord) -> InstrumentRow {
    InstrumentRow(
      id: source.id,
      recordName: InstrumentRow.recordName(for: source.id),
      kind: source.kind,
      name: source.name,
      decimals: source.decimals,
      ticker: source.ticker,
      exchange: source.exchange,
      chainId: source.chainId,
      contractAddress: source.contractAddress,
      coingeckoId: source.coingeckoId,
      cryptocompareSymbol: source.cryptocompareSymbol,
      binanceSymbol: source.binanceSymbol,
      encodedSystemFields: source.encodedSystemFields)
  }

  // MARK: - Categories

  func migrateCategoriesIfNeeded(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    defaults: UserDefaults
  ) async throws {
    guard !defaults.bool(forKey: Self.categoriesFlag) else { return }
    var committed = false
    var rowCount = 0
    defer {
      if committed {
        defaults.set(true, forKey: Self.categoriesFlag)
        logger.info(
          """
          SwiftData → GRDB migration complete for CategoryRecord: \
          \(rowCount, privacy: .public) row(s) copied
          """)
      }
    }
    let unsortedRows = try Self.fetchSwiftDataRows(
      modelContainer: modelContainer,
      recordTypeDescription: "CategoryRecord",
      type: CategoryRecord.self,
      mapper: Self.mapCategory(_:),
      logger: logger)
    // Self-referential FK: a category's `parent_id` references another
    // category in the same table. Sort parents before children so the
    // child insert has its parent already on disk under the FK pragma.
    let mappedRows = Self.sortCategoriesParentFirst(unsortedRows)
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

  /// Returns the rows in parent-first order (Kahn-style topological
  /// sort). Categories without a `parent_id` come first; each pass
  /// emits any row whose parent is already present. Cycles are
  /// degenerate by construction (the SwiftData layer's invariants
  /// prevent them) but a defensive fall-through emits whatever is left
  /// in original order if a cycle is encountered.
  static func sortCategoriesParentFirst(_ rows: [CategoryRow]) -> [CategoryRow] {
    var emitted: Set<UUID> = []
    var remaining = rows
    var ordered: [CategoryRow] = []
    ordered.reserveCapacity(rows.count)
    while !remaining.isEmpty {
      var progressed = false
      var stillBlocked: [CategoryRow] = []
      for row in remaining {
        let parentSettled = row.parentId.map(emitted.contains) ?? true
        if parentSettled {
          ordered.append(row)
          emitted.insert(row.id)
          progressed = true
        } else {
          stillBlocked.append(row)
        }
      }
      if !progressed {
        // No row could resolve its parent — emit the remainder verbatim
        // and let the FK enforcement surface the bad data instead of
        // looping forever.
        ordered.append(contentsOf: stillBlocked)
        return ordered
      }
      remaining = stillBlocked
    }
    return ordered
  }

  /// Maps a SwiftData `CategoryRecord` to a `CategoryRow`. Self-referential
  /// `parentId` is preserved; the parent row's FK resolves because a
  /// category's parent is itself a `CategoryRecord` migrated in the
  /// same transaction.
  private static func mapCategory(_ source: CategoryRecord) -> CategoryRow {
    CategoryRow(
      id: source.id,
      recordName: CategoryRow.recordName(for: source.id),
      name: source.name,
      parentId: source.parentId,
      encodedSystemFields: source.encodedSystemFields)
  }

  // MARK: - Accounts

  func migrateAccountsIfNeeded(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    defaults: UserDefaults
  ) async throws {
    guard !defaults.bool(forKey: Self.accountsFlag) else { return }
    var committed = false
    var rowCount = 0
    defer {
      if committed {
        defaults.set(true, forKey: Self.accountsFlag)
        logger.info(
          """
          SwiftData → GRDB migration complete for AccountRecord: \
          \(rowCount, privacy: .public) row(s) copied
          """)
      }
    }
    let mappedRows = try Self.fetchSwiftDataRows(
      modelContainer: modelContainer,
      recordTypeDescription: "AccountRecord",
      type: AccountRecord.self,
      mapper: Self.mapAccount(_:),
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

  private static func mapAccount(_ source: AccountRecord) -> AccountRow {
    AccountRow(
      id: source.id,
      recordName: AccountRow.recordName(for: source.id),
      name: source.name,
      type: source.type,
      instrumentId: source.instrumentId,
      position: source.position,
      isHidden: source.isHidden,
      encodedSystemFields: source.encodedSystemFields)
  }

}
