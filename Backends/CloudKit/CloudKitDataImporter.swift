import Foundation
import GRDB
import OSLog
import SwiftData

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

/// Imports exported data into a profile's stores. Writes the synced
/// record types to the GRDB-backed `data.sqlite` (the canonical store
/// that the runtime reads from) and mirrors them to the SwiftData
/// container so legacy verifiers and any straggling SwiftData callers
/// see consistent counts.
///
/// Runs on the MainActor because the SwiftData mirror writes use the
/// container's `mainContext`. The GRDB writes themselves are
/// queue-serialised and don't require main-actor isolation.
@MainActor
struct CloudKitDataImporter {
  private let modelContainer: ModelContainer
  private let database: any DatabaseWriter
  private let currencyCode: String
  private let logger = Logger(subsystem: "com.moolah.app", category: "Import")

  init(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    currencyCode: String
  ) {
    self.modelContainer = modelContainer
    self.database = database
    self.currencyCode = currencyCode
  }

  @discardableResult
  func importData(
    _ data: ExportedData,
    progress: ((String, Double) -> Void)? = nil
  ) async throws -> ImportResult {
    let context = modelContainer.mainContext
    let totalSteps = 7.0
    var step = 0.0

    // 0. Instruments (must exist before records that reference them)
    for instrument in data.instruments {
      context.insert(InstrumentRecord.from(instrument))
    }

    progress?("categories", step / totalSteps)
    insertCategories(data.categories, into: context)
    step += 1
    await Task.yield()

    progress?("accounts", step / totalSteps)
    insertAccounts(data.accounts, into: context)
    step += 1
    await Task.yield()

    progress?("earmarks", step / totalSteps)
    for earmark in data.earmarks {
      context.insert(EarmarkRecord.from(earmark))
    }
    step += 1
    await Task.yield()

    progress?("budget items", step / totalSteps)
    let budgetItemCount = insertBudgetItems(data.earmarkBudgets, into: context)
    step += 1
    await Task.yield()

    progress?("transactions", step / totalSteps)
    insertTransactions(data.transactions, into: context)
    step += 1
    await Task.yield()

    progress?("investment values", step / totalSteps)
    let investmentValueCount = insertInvestmentValues(data.investmentValues, into: context)
    step += 1
    await Task.yield()

    progress?("saving", step / totalSteps)
    try context.save()

    // Mirror everything to GRDB so the runtime stores (which read
    // exclusively from `data.sqlite`) see the imported data. Order:
    // parents before children to satisfy enforced FKs.
    try writeGRDB(data: data)

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

  private func insertCategories(_ categories: [Category], into context: ModelContext) {
    for category in categories {
      context.insert(
        CategoryRecord(
          id: category.id,
          name: category.name,
          parentId: category.parentId))
    }
  }

  private func insertAccounts(_ accounts: [Account], into context: ModelContext) {
    for account in accounts {
      context.insert(
        AccountRecord(
          id: account.id,
          name: account.name,
          type: account.type.rawValue,
          instrumentId: account.instrument.id,
          position: account.position,
          isHidden: account.isHidden))
    }
  }

  private func insertBudgetItems(
    _ budgets: [UUID: [EarmarkBudgetItem]], into context: ModelContext
  ) -> Int {
    var budgetItemCount = 0
    for (earmarkId, items) in budgets {
      for item in items {
        context.insert(
          EarmarkBudgetItemRecord(
            id: item.id,
            earmarkId: earmarkId,
            categoryId: item.categoryId,
            amount: item.amount.storageValue,
            instrumentId: item.amount.instrument.id))
        budgetItemCount += 1
      }
    }
    return budgetItemCount
  }

  private func insertTransactions(_ transactions: [Transaction], into context: ModelContext) {
    for txn in transactions {
      let record = TransactionRecord.from(txn)
      context.insert(record)
      for (index, leg) in txn.legs.enumerated() {
        let legRecord = TransactionLegRecord.from(leg, transactionId: txn.id, sortOrder: index)
        context.insert(legRecord)
      }
    }
  }

  private func insertInvestmentValues(
    _ values: [UUID: [InvestmentValue]], into context: ModelContext
  ) -> Int {
    var investmentValueCount = 0
    for (accountId, values) in values {
      for value in values {
        context.insert(
          InvestmentValueRecord(
            id: UUID(),
            accountId: accountId,
            date: value.date,
            value: value.value.storageValue,
            instrumentId: value.value.instrument.id))
        investmentValueCount += 1
      }
    }
    return investmentValueCount
  }

  // MARK: - GRDB mirror

  /// Writes every record type from `data` into the per-profile GRDB
  /// database. Parents go first so FK references resolve as the single
  /// `database.write` transaction commits; non-fiat instruments are
  /// upserted up-front so accounts and legs that reference them by id
  /// can resolve their full domain `Instrument` on read.
  ///
  /// TODO(#575): make `writeGRDB` `async` and call
  /// `try await database.write { … }` so heavy imports don't block the
  /// main thread —
  /// https://github.com/ajsutton/moolah-native/issues/575
  private func writeGRDB(data: ExportedData) throws {
    try database.write { database in
      try Self.writeInstrumentsAndCategories(data: data, database: database)
      try Self.writeAccountsAndEarmarks(data: data, database: database)
      try Self.writeTransactions(data: data, database: database)
      try Self.writeInvestmentValues(data: data, database: database)
    }
  }

  private static func writeInstrumentsAndCategories(
    data: ExportedData, database: Database
  ) throws {
    for instrument in data.instruments {
      try InstrumentRow(domain: instrument).upsert(database)
    }
    for category in data.categories {
      try CategoryRow(domain: category).upsert(database)
    }
  }

  private static func writeAccountsAndEarmarks(
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

  private static func writeTransactions(
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

  private static func writeInvestmentValues(
    data: ExportedData, database: Database
  ) throws {
    for (accountId, values) in data.investmentValues {
      for value in values {
        try InvestmentValueRow(domain: value, accountId: accountId).upsert(database)
      }
    }
  }
}
