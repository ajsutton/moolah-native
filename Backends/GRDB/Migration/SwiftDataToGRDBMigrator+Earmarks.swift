// Backends/GRDB/Migration/SwiftDataToGRDBMigrator+Earmarks.swift

import Foundation
import GRDB
import SwiftData

// Per-type SwiftData → GRDB migrators for the earmark half of the core
// financial graph (earmarks, earmark budget items, investment values).
// Companion to `SwiftDataToGRDBMigrator+CoreFinancialGraph.swift`. Same
// pattern: `defer`-then-flag, idempotent `upsert`, ordered so parents
// commit before children.

extension SwiftDataToGRDBMigrator {

  // MARK: - Earmarks

  func migrateEarmarksIfNeeded(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    defaults: UserDefaults
  ) throws {
    guard !defaults.bool(forKey: Self.earmarksFlag) else { return }
    var committed = false
    var rowCount = 0
    defer {
      if committed {
        defaults.set(true, forKey: Self.earmarksFlag)
        logger.info(
          """
          SwiftData → GRDB migration complete for EarmarkRecord: \
          \(rowCount, privacy: .public) row(s) copied
          """)
      }
    }
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<EarmarkRecord>()
    let sourceRows: [EarmarkRecord]
    do {
      sourceRows = try context.fetch(descriptor)
    } catch {
      logger.error(
        """
        SwiftData fetch for EarmarkRecord failed during GRDB \
        migration: \(error.localizedDescription, privacy: .public). \
        Migration aborted; will retry next launch.
        """)
      throw error
    }
    let mappedRows = sourceRows.map(Self.mapEarmark(_:))
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

  /// Maps a SwiftData `EarmarkRecord` to an `EarmarkRow`. The legacy
  /// `savingsTargetInstrumentId` column is preserved verbatim — the
  /// reader ignores it in `toDomain`, but keeping the bytes keeps the
  /// CKRecord wire format byte-identical.
  private static func mapEarmark(_ source: EarmarkRecord) -> EarmarkRow {
    EarmarkRow(
      id: source.id,
      recordName: EarmarkRow.recordName(for: source.id),
      name: source.name,
      position: source.position,
      isHidden: source.isHidden,
      instrumentId: source.instrumentId,
      savingsTarget: source.savingsTarget,
      savingsTargetInstrumentId: source.savingsTargetInstrumentId,
      savingsStartDate: source.savingsStartDate,
      savingsEndDate: source.savingsEndDate,
      encodedSystemFields: source.encodedSystemFields)
  }

  // MARK: - Earmark budget items

  func migrateEarmarkBudgetItemsIfNeeded(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    defaults: UserDefaults
  ) throws {
    guard !defaults.bool(forKey: Self.earmarkBudgetItemsFlag) else { return }
    var committed = false
    var rowCount = 0
    defer {
      if committed {
        defaults.set(true, forKey: Self.earmarkBudgetItemsFlag)
        logger.info(
          """
          SwiftData → GRDB migration complete for EarmarkBudgetItemRecord: \
          \(rowCount, privacy: .public) row(s) copied
          """)
      }
    }
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<EarmarkBudgetItemRecord>()
    let sourceRows: [EarmarkBudgetItemRecord]
    do {
      sourceRows = try context.fetch(descriptor)
    } catch {
      logger.error(
        """
        SwiftData fetch for EarmarkBudgetItemRecord failed during GRDB \
        migration: \(error.localizedDescription, privacy: .public). \
        Migration aborted; will retry next launch.
        """)
      throw error
    }
    let mappedRows = sourceRows.map(Self.mapEarmarkBudgetItem(_:))
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

  private static func mapEarmarkBudgetItem(
    _ source: EarmarkBudgetItemRecord
  ) -> EarmarkBudgetItemRow {
    EarmarkBudgetItemRow(
      id: source.id,
      recordName: EarmarkBudgetItemRow.recordName(for: source.id),
      earmarkId: source.earmarkId,
      categoryId: source.categoryId,
      amount: source.amount,
      instrumentId: source.instrumentId,
      encodedSystemFields: source.encodedSystemFields)
  }

  // MARK: - Investment values

  func migrateInvestmentValuesIfNeeded(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    defaults: UserDefaults
  ) throws {
    guard !defaults.bool(forKey: Self.investmentValuesFlag) else { return }
    var committed = false
    var rowCount = 0
    defer {
      if committed {
        defaults.set(true, forKey: Self.investmentValuesFlag)
        logger.info(
          """
          SwiftData → GRDB migration complete for InvestmentValueRecord: \
          \(rowCount, privacy: .public) row(s) copied
          """)
      }
    }
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<InvestmentValueRecord>()
    let sourceRows: [InvestmentValueRecord]
    do {
      sourceRows = try context.fetch(descriptor)
    } catch {
      logger.error(
        """
        SwiftData fetch for InvestmentValueRecord failed during GRDB \
        migration: \(error.localizedDescription, privacy: .public). \
        Migration aborted; will retry next launch.
        """)
      throw error
    }
    let mappedRows = sourceRows.map(Self.mapInvestmentValue(_:))
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

  private static func mapInvestmentValue(
    _ source: InvestmentValueRecord
  ) -> InvestmentValueRow {
    InvestmentValueRow(
      id: source.id,
      recordName: InvestmentValueRow.recordName(for: source.id),
      accountId: source.accountId,
      date: source.date,
      value: source.value,
      instrumentId: source.instrumentId,
      encodedSystemFields: source.encodedSystemFields)
  }

}
