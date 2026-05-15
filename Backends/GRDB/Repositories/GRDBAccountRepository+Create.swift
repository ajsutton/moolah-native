// Backends/GRDB/Repositories/GRDBAccountRepository+Create.swift

import Foundation
import GRDB

// `performAccountInsert` + `OpeningBalanceInserts` extracted from
// `GRDBAccountRepository` so the main type body stays under SwiftLint's
// `type_body_length` and `file_length` budgets after the
// `onInstrumentChanged` hook plumbing widened the create flow.
extension GRDBAccountRepository {
  /// Captures the ids written by `create(_:openingBalance:)` so the
  /// caller can fan out hook fires after the write transaction commits.
  /// Non-fiat instrument registration is done by `create` itself via
  /// `instrumentRegistrar.registerResolvable` *before* this write — it
  /// is no longer part of the per-profile insert.
  struct OpeningBalanceInserts: Sendable {
    let transactionId: UUID?
    let legId: UUID?
  }

  /// Single-statement body of `create(_:openingBalance:)`'s
  /// `database.write { … }` block. Inserts the account row, and — when
  /// the caller passes a non-zero opening balance — a one-leg
  /// `TransactionRow` + `TransactionLegRow` to seed the account's
  /// initial position. Returns the ids the caller fans out as hooks.
  static func performAccountInsert(
    database: Database,
    account: Account,
    openingBalance: InstrumentAmount?,
    openingBalanceDate: Date
  ) throws -> OpeningBalanceInserts {
    let accountRow = AccountRow(domain: account)
    try accountRow.insert(database)

    // No opening balance — only the account row was inserted.
    guard let openingBalance, !openingBalance.isZero else {
      return OpeningBalanceInserts(transactionId: nil, legId: nil)
    }

    let txnId = UUID()
    try makeOpeningBalanceTxnRow(id: txnId, date: openingBalanceDate).insert(database)
    let legId = UUID()
    try makeOpeningBalanceLegRow(
      id: legId, transactionId: txnId, account: account, openingBalance: openingBalance
    ).insert(database)
    return OpeningBalanceInserts(transactionId: txnId, legId: legId)
  }

  private static func makeOpeningBalanceTxnRow(id: UUID, date: Date) -> TransactionRow {
    TransactionRow(
      id: id,
      recordName: TransactionRow.recordName(for: id),
      date: date,
      payee: nil,
      notes: nil,
      recurPeriod: nil,
      recurEvery: nil,
      importOriginRawDescription: nil,
      importOriginBankReference: nil,
      importOriginRawAmount: nil,
      importOriginRawBalance: nil,
      importOriginImportedAt: nil,
      importOriginImportSessionId: nil,
      importOriginSourceFilename: nil,
      importOriginParserIdentifier: nil,
      encodedSystemFields: nil)
  }

  private static func makeOpeningBalanceLegRow(
    id: UUID,
    transactionId: UUID,
    account: Account,
    openingBalance: InstrumentAmount
  ) -> TransactionLegRow {
    TransactionLegRow(
      id: id,
      recordName: TransactionLegRow.recordName(for: id),
      transactionId: transactionId,
      accountId: account.id,
      instrumentId: account.instrument.id,
      quantity: openingBalance.storageValue,
      type: TransactionType.openingBalance.rawValue,
      categoryId: nil,
      earmarkId: nil,
      sortOrder: 0,
      encodedSystemFields: nil)
  }
}
