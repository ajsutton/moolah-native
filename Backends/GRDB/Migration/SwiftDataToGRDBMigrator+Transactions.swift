// Backends/GRDB/Migration/SwiftDataToGRDBMigrator+Transactions.swift

import Foundation
import GRDB
import SwiftData

// Per-type SwiftData → GRDB migrators for the transaction half of the
// core financial graph (transactions and transaction legs). Companion
// to `SwiftDataToGRDBMigrator+CoreFinancialGraph.swift`. Same pattern:
// `defer`-then-flag, idempotent `upsert`, ordered so parents commit
// before children.

extension SwiftDataToGRDBMigrator {

  // MARK: - Transactions

  func migrateTransactionsIfNeeded(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    defaults: UserDefaults
  ) async throws {
    guard !defaults.bool(forKey: Self.transactionsFlag) else { return }
    var committed = false
    var rowCount = 0
    defer {
      if committed {
        defaults.set(true, forKey: Self.transactionsFlag)
        logger.info(
          """
          SwiftData → GRDB migration complete for TransactionRecord: \
          \(rowCount, privacy: .public) row(s) copied
          """)
      }
    }
    let mappedRows = try Self.fetchSwiftDataRows(
      modelContainer: modelContainer,
      recordTypeDescription: "TransactionRecord",
      type: TransactionRecord.self,
      mapper: Self.mapTransaction(_:),
      logger: logger)
    if !mappedRows.isEmpty {
      try await database.write { database in
        for row in mappedRows {
          try row.upsert(database)
        }
      }
    }
    rowCount = mappedRows.count
    committed = true
  }

  /// Maps a SwiftData `TransactionRecord` to a `TransactionRow`. The
  /// eight denormalised `importOrigin*` columns are copied verbatim;
  /// `importOriginRawAmount` and `importOriginRawBalance` are stored
  /// as Decimal-as-String on both sides (preserving precision across
  /// the SwiftData ↔ CloudKit ↔ Domain round-trip).
  private static func mapTransaction(_ source: TransactionRecord) -> TransactionRow {
    TransactionRow(
      id: source.id,
      recordName: TransactionRow.recordName(for: source.id),
      date: source.date,
      payee: source.payee,
      notes: source.notes,
      recurPeriod: source.recurPeriod,
      recurEvery: source.recurEvery,
      importOriginRawDescription: source.importOriginRawDescription,
      importOriginBankReference: source.importOriginBankReference,
      importOriginRawAmount: source.importOriginRawAmount,
      importOriginRawBalance: source.importOriginRawBalance,
      importOriginImportedAt: source.importOriginImportedAt,
      importOriginImportSessionId: source.importOriginImportSessionId,
      importOriginSourceFilename: source.importOriginSourceFilename,
      importOriginParserIdentifier: source.importOriginParserIdentifier,
      encodedSystemFields: source.encodedSystemFields)
  }

  // MARK: - Transaction legs

  func migrateTransactionLegsIfNeeded(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    defaults: UserDefaults
  ) async throws {
    guard !defaults.bool(forKey: Self.transactionLegsFlag) else { return }
    var committed = false
    var rowCount = 0
    defer {
      if committed {
        defaults.set(true, forKey: Self.transactionLegsFlag)
        logger.info(
          """
          SwiftData → GRDB migration complete for TransactionLegRecord: \
          \(rowCount, privacy: .public) row(s) copied
          """)
      }
    }
    let mappedRows = try Self.fetchSwiftDataRows(
      modelContainer: modelContainer,
      recordTypeDescription: "TransactionLegRecord",
      type: TransactionLegRecord.self,
      mapper: Self.mapTransactionLeg(_:),
      logger: logger)
    if !mappedRows.isEmpty {
      try await database.write { database in
        for row in mappedRows {
          try row.upsert(database)
        }
      }
    }
    rowCount = mappedRows.count
    committed = true
  }

  /// Maps a SwiftData `TransactionLegRecord` to a `TransactionLegRow`.
  /// `quantity` is the `InstrumentAmount` storage form (Int64 × 10^8)
  /// on both sides — copied verbatim. `type` is the `TransactionType`
  /// raw value, also a verbatim copy.
  private static func mapTransactionLeg(_ source: TransactionLegRecord) -> TransactionLegRow {
    TransactionLegRow(
      id: source.id,
      recordName: TransactionLegRow.recordName(for: source.id),
      transactionId: source.transactionId,
      accountId: source.accountId,
      instrumentId: source.instrumentId,
      quantity: source.quantity,
      type: source.type,
      categoryId: source.categoryId,
      earmarkId: source.earmarkId,
      sortOrder: source.sortOrder,
      encodedSystemFields: source.encodedSystemFields)
  }
}
