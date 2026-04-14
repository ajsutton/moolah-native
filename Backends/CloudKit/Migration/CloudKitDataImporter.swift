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
  private let logger = Logger(subsystem: "com.moolah.app", category: "Migration")

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

    // 1. Categories (no dependencies)
    progress?("categories", step / totalSteps)
    for category in data.categories {
      let record = CategoryRecord(
        id: category.id,
        name: category.name,
        parentId: category.parentId
      )
      context.insert(record)
    }
    step += 1
    await Task.yield()

    // 2. Accounts (no dependencies)
    progress?("accounts", step / totalSteps)
    for account in data.accounts {
      let record = AccountRecord(
        id: account.id,
        name: account.name,
        type: account.type.rawValue,
        position: account.position,
        isHidden: account.isHidden
      )
      context.insert(record)
    }
    step += 1
    await Task.yield()

    // 3. Earmarks (no dependencies)
    progress?("earmarks", step / totalSteps)
    for earmark in data.earmarks {
      let record = EarmarkRecord(
        id: earmark.id,
        name: earmark.name,
        position: earmark.position,
        isHidden: earmark.isHidden,
        savingsTarget: earmark.savingsGoal?.storageValue,
        savingsTargetInstrumentId: earmark.savingsGoal?.instrument.id,
        savingsStartDate: earmark.savingsStartDate,
        savingsEndDate: earmark.savingsEndDate
      )
      context.insert(record)
    }
    step += 1
    await Task.yield()

    // 4. Earmark budget items
    progress?("budget items", step / totalSteps)
    var budgetItemCount = 0
    for (earmarkId, items) in data.earmarkBudgets {
      for item in items {
        let record = EarmarkBudgetItemRecord(
          id: item.id,
          earmarkId: earmarkId,
          categoryId: item.categoryId,
          amount: item.amount.storageValue,
          instrumentId: item.amount.instrument.id
        )
        context.insert(record)
        budgetItemCount += 1
      }
    }
    step += 1
    await Task.yield()

    // 5. Transactions
    progress?("transactions", step / totalSteps)
    for txn in data.transactions {
      let record = TransactionRecord.from(txn)
      context.insert(record)
      for (index, leg) in txn.legs.enumerated() {
        let legRecord = TransactionLegRecord.from(leg, transactionId: txn.id, sortOrder: index)
        context.insert(legRecord)
      }
    }
    step += 1
    await Task.yield()

    // 6. Investment values
    progress?("investment values", step / totalSteps)
    var investmentValueCount = 0
    for (accountId, values) in data.investmentValues {
      for value in values {
        let record = InvestmentValueRecord(
          id: UUID(),
          accountId: accountId,
          date: value.date,
          value: value.value.storageValue,
          instrumentId: value.value.instrument.id
        )
        context.insert(record)
        investmentValueCount += 1
      }
    }
    step += 1
    await Task.yield()

    // 7. Save all records atomically
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
}
