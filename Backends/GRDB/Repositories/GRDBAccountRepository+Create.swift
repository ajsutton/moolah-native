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
  /// `instrument` is non-nil only when the account's instrument was
  /// non-fiat AND no row existed for it in the per-profile copy — the
  /// create path auto-inserted one and the caller must publish it to
  /// the shared registry for cross-device propagation.
  struct OpeningBalanceInserts: Sendable {
    let transactionId: UUID?
    let legId: UUID?
    let instrument: Instrument?
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
    let insertedInstrument = try ensureNonFiatInstrumentRow(
      database: database, instrument: account.instrument)
    let accountRow = AccountRow(domain: account)
    try accountRow.insert(database)

    // No opening balance — only the account row was inserted.
    guard let openingBalance, !openingBalance.isZero else {
      return OpeningBalanceInserts(
        transactionId: nil, legId: nil, instrument: insertedInstrument)
    }

    let txnId = UUID()
    try makeOpeningBalanceTxnRow(id: txnId, date: openingBalanceDate).insert(database)
    let legId = UUID()
    try makeOpeningBalanceLegRow(
      id: legId, transactionId: txnId, account: account, openingBalance: openingBalance
    ).insert(database)
    return OpeningBalanceInserts(
      transactionId: txnId, legId: legId, instrument: insertedInstrument)
  }

  /// Inserts the placeholder `instrument` row for stocks / crypto if it
  /// isn't already present in the per-profile copy. Fiat is ambient —
  /// synthesised from `Locale.Currency.isoCurrencies` in
  /// `fetchInstrumentMap`. Returns the inserted `Instrument` (or `nil`
  /// for fiat / pre-existing rows) so the caller's hook fan-out can
  /// publish it to the shared registry on the profile-index zone.
  /// Without that publish the row would stay local-only and sibling
  /// devices would fall back to `Instrument.fiat(code: id)` for a
  /// stock (see `InstrumentLocalSyncQueueTests`).
  private static func ensureNonFiatInstrumentRow(
    database: Database, instrument: Instrument
  ) throws -> Instrument? {
    guard instrument.kind != .fiatCurrency else { return nil }
    let exists =
      try InstrumentRow
      .filter(InstrumentRow.Columns.id == instrument.id)
      .fetchOne(database)
    guard exists == nil else { return nil }
    try InstrumentRow(domain: instrument).insert(database)
    return instrument
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
