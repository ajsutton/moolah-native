import Foundation
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

/// Imports exported data into SwiftData records scoped to a specific profile.
/// Runs on the MainActor using the container's mainContext to ensure data
/// is immediately visible to CloudKit repositories.
@MainActor
struct CloudKitDataImporter {
  private let modelContainer: ModelContainer
  private let currencyCode: String
  private let logger = Logger(subsystem: "com.moolah.app", category: "Import")

  init(modelContainer: ModelContainer, currencyCode: String) {
    self.modelContainer = modelContainer
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
}
