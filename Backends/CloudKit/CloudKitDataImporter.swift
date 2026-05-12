import Foundation
import GRDB
import OSLog

struct ImportResult: Sendable {
  let accountCount: Int
  let categoryCount: Int
  let earmarkCount: Int
  let budgetItemCount: Int
  let transactionCount: Int
  let investmentValueCount: Int

  var totalCount: Int {
    accountCount + categoryCount + earmarkCount + budgetItemCount + transactionCount
      + investmentValueCount
  }
}

/// Imports exported data into a profile's GRDB-backed `data.sqlite`,
/// which is the canonical store the runtime reads from. The GRDB writes
/// are queue-serialised inside `database.write`, so the importer itself
/// does not need any actor isolation.
struct CloudKitDataImporter {
  private let database: any DatabaseWriter
  private let currencyCode: String
  private let logger = Logger(subsystem: "com.moolah.app", category: "Import")

  init(
    database: any DatabaseWriter,
    currencyCode: String
  ) {
    self.database = database
    self.currencyCode = currencyCode
  }

  @discardableResult
  func importData(
    _ data: ExportedData,
    progress: ((String, Double) -> Void)? = nil
  ) async throws -> ImportResult {
    // The GRDB write is a single transaction, so per-stage progress is
    // approximate: fire "saving" before the transaction so the call site
    // can render a spinner, yield once so the progress callback can be
    // observed, then write everything, then fire "done".
    progress?("saving", 0.0)
    await Task.yield()

    try await writeGRDB(data: data)

    progress?("done", 1.0)

    let budgetItemCount = data.earmarkBudgets.values.reduce(0) { $0 + $1.count }
    let investmentValueCount = data.investmentValues.values.reduce(0) { $0 + $1.count }

    logger.info(
      "Import complete: \(data.accounts.count) accounts, \(data.transactions.count) transactions, \(investmentValueCount) investment values"
    )

    return ImportResult(
      accountCount: data.accounts.count,
      categoryCount: data.categories.count,
      earmarkCount: data.earmarks.count,
      budgetItemCount: budgetItemCount,
      transactionCount: data.transactions.count,
      investmentValueCount: investmentValueCount
    )
  }

  // MARK: - GRDB writes

  /// Writes every record type from `data` into the per-profile GRDB
  /// database. Parents go first so FK references resolve as the single
  /// `database.write` transaction commits; non-fiat instruments are
  /// upserted up-front so accounts and legs that reference them by id
  /// can resolve their full domain `Instrument` on read.
  private func writeGRDB(data: ExportedData) async throws {
    try await database.write { database in
      try Self.writeInstrumentsAndCategories(data: data, database: database)
      try Self.writeAccountsAndEarmarks(data: data, database: database)
      try Self.writeTransactions(data: data, database: database)
      try Self.writeInvestmentValues(data: data, database: database)
    }
  }

  nonisolated private static func writeInstrumentsAndCategories(
    data: ExportedData, database: Database
  ) throws {
    for instrument in data.instruments {
      try InstrumentRow(domain: instrument).upsert(database)
    }
    for category in data.categories {
      try CategoryRow(domain: category).upsert(database)
    }
  }

  nonisolated private static func writeAccountsAndEarmarks(
    data: ExportedData, database: Database
  ) throws {
    for account in data.accounts {
      if account.instrument.kind != .fiatCurrency {
        try InstrumentRow(domain: account.instrument).upsert(database)
      }
      try AccountRow(domain: account).upsert(database)
    }
    for earmark in data.earmarks {
      try EarmarkRow(domain: earmark).upsert(database)
    }
    for (earmarkId, items) in data.earmarkBudgets {
      for item in items {
        try EarmarkBudgetItemRow(domain: item, earmarkId: earmarkId).upsert(database)
      }
    }
  }

  nonisolated private static func writeTransactions(
    data: ExportedData, database: Database
  ) throws {
    for txn in data.transactions {
      try TransactionRow(domain: txn).upsert(database)
      for (index, leg) in txn.legs.enumerated() {
        if leg.instrument.kind != .fiatCurrency {
          try InstrumentRow(domain: leg.instrument).upsert(database)
        }
        try TransactionLegRow(domain: leg, transactionId: txn.id, sortOrder: index)
          .upsert(database)
      }
    }
  }

  nonisolated private static func writeInvestmentValues(
    data: ExportedData, database: Database
  ) throws {
    for (accountId, values) in data.investmentValues {
      for value in values {
        try InvestmentValueRow(domain: value, accountId: accountId).upsert(database)
      }
    }
  }
}
