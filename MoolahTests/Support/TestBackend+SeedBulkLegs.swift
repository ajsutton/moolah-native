import Foundation
import GRDB

@testable import Moolah

// Bulk transaction-leg seeding for the sync-reactivity benchmarks. Lives
// in a dedicated extension file (rather than `TestBackend.swift`) to keep
// the parent enum body under SwiftLint's `type_body_length` threshold and
// to mirror the existing `TestBackend+SeedEarmarkTransactions.swift`
// pattern.
extension TestBackend {

  /// Seeds `count` transactions, each with one leg, distributed
  /// round-robin across `accountIds`. Used by `SyncReactivityBenchmarks`
  /// to simulate a 50k-leg bulk-sync apply against a freshly-built
  /// in-memory database.
  ///
  /// All inserts run inside a single GRDB write so the per-row overhead
  /// is dominated by the SQL prepare/exec rather than transaction
  /// commit. No placeholder-parent resolution (the caller is expected to
  /// have seeded `accountIds` already), no instrument materialisation
  /// (legs use `Instrument.defaultTestInstrument`).
  ///
  /// Throws (rather than trapping like the rest of the seed helpers) so
  /// benchmarks can surface a setup failure as an `XCTFail` instead of a
  /// process abort, which keeps the rest of the benchmark suite running.
  static func seedBulkTransactionLegs(
    count: Int,
    accountIds: [UUID],
    in database: any DatabaseWriter,
    instrument: Instrument = .defaultTestInstrument
  ) throws {
    precondition(!accountIds.isEmpty, "seedBulkTransactionLegs requires at least one accountId")
    // Capture `now` once at the boundary so all 50k rows share a single
    // Date() instance — per CODE_GUIDE.md "Date() only at boundaries" and
    // the data-seeding rule "use deterministic data".
    let now = Date()
    try database.write { database in
      for i in 0..<count {
        try insertBulkLeg(
          index: i,
          accountId: accountIds[i % accountIds.count],
          instrument: instrument,
          date: now,
          database: database)
      }
    }
  }

  /// Inserts one transaction + one leg row for the bulk-seed loop.
  /// Extracted from `seedBulkTransactionLegs` so the closure passed to
  /// `database.write` stays under SwiftLint's `closure_body_length`.
  private static func insertBulkLeg(
    index i: Int,
    accountId: UUID,
    instrument: Instrument,
    date: Date,
    database: Database
  ) throws {
    let txnId = UUID()
    let txnRow = TransactionRow(
      id: txnId,
      recordName: TransactionRow.recordName(for: txnId),
      date: date,
      payee: "Bulk \(i)",
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
    try txnRow.insert(database)
    let legId = UUID()
    let quantity = InstrumentAmount(
      quantity: Decimal(-((i % 500) + 1)),
      instrument: instrument
    ).storageValue
    let legRow = TransactionLegRow(
      id: legId,
      recordName: TransactionLegRow.recordName(for: legId),
      transactionId: txnId,
      accountId: accountId,
      instrumentId: instrument.id,
      quantity: quantity,
      type: TransactionType.expense.rawValue,
      categoryId: nil,
      earmarkId: nil,
      sortOrder: 0,
      encodedSystemFields: nil)
    try legRow.insert(database)
  }
}
