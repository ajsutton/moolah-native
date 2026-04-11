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
/// Uses DefaultSerialModelExecutor to ensure the ModelContext has proper thread
/// affinity (plain actors use the cooperative pool which can silently corrupt saves).
actor CloudKitDataImporter: ModelActor {
  nonisolated let modelContainer: ModelContainer
  nonisolated let modelExecutor: any ModelExecutor
  private let profileId: UUID
  private let currencyCode: String
  private let logger = Logger(subsystem: "com.moolah.app", category: "Migration")

  enum ImportProgress: Sendable {
    case importing(step: String, current: Int, total: Int)
    case importComplete(ImportResult)
    case failed(Error)
  }

  init(modelContainer: ModelContainer, profileId: UUID, currencyCode: String) {
    self.modelContainer = modelContainer
    let context = ModelContext(modelContainer)
    self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    self.profileId = profileId
    self.currencyCode = currencyCode
  }

  func importData(
    _ data: ExportedData,
    progress: @escaping @Sendable (ImportProgress) -> Void
  ) throws -> ImportResult {
    // 1. Categories (no dependencies)
    progress(.importing(step: "categories", current: 0, total: data.categories.count))
    for (i, category) in data.categories.enumerated() {
      let record = CategoryRecord(
        id: category.id,
        profileId: profileId,
        name: category.name,
        parentId: category.parentId
      )
      modelContext.insert(record)
      if i % 50 == 0 {
        progress(.importing(step: "categories", current: i, total: data.categories.count))
      }
    }

    // 2. Accounts (no dependencies)
    progress(.importing(step: "accounts", current: 0, total: data.accounts.count))
    for account in data.accounts {
      let record = AccountRecord(
        id: account.id,
        profileId: profileId,
        name: account.name,
        type: account.type.rawValue,
        position: account.position,
        isHidden: account.isHidden,
        currencyCode: currencyCode
      )
      modelContext.insert(record)
    }

    // 3. Earmarks (no dependencies)
    progress(.importing(step: "earmarks", current: 0, total: data.earmarks.count))
    for earmark in data.earmarks {
      let record = EarmarkRecord(
        id: earmark.id,
        profileId: profileId,
        name: earmark.name,
        position: earmark.position,
        isHidden: earmark.isHidden,
        savingsTarget: earmark.savingsGoal?.cents,
        currencyCode: currencyCode,
        savingsStartDate: earmark.savingsStartDate,
        savingsEndDate: earmark.savingsEndDate
      )
      modelContext.insert(record)
    }

    // 4. Earmark budget items
    var budgetItemCount = 0
    for (earmarkId, items) in data.earmarkBudgets {
      for item in items {
        let record = EarmarkBudgetItemRecord(
          id: item.id,
          profileId: profileId,
          earmarkId: earmarkId,
          categoryId: item.categoryId,
          amount: item.amount.cents,
          currencyCode: currencyCode
        )
        modelContext.insert(record)
        budgetItemCount += 1
      }
    }

    // 5. Transactions (largest dataset — batch insert with progress)
    let totalTxns = data.transactions.count
    progress(.importing(step: "transactions", current: 0, total: totalTxns))
    for (i, txn) in data.transactions.enumerated() {
      let record = TransactionRecord(
        id: txn.id,
        profileId: profileId,
        type: txn.type.rawValue,
        date: txn.date,
        accountId: txn.accountId,
        toAccountId: txn.toAccountId,
        amount: txn.amount.cents,
        currencyCode: currencyCode,
        payee: txn.payee,
        notes: txn.notes,
        categoryId: txn.categoryId,
        earmarkId: txn.earmarkId,
        recurPeriod: txn.recurPeriod?.rawValue,
        recurEvery: txn.recurEvery
      )
      modelContext.insert(record)

      if i % 100 == 0 {
        progress(.importing(step: "transactions", current: i, total: totalTxns))
      }
    }

    // 6. Investment values (per investment account)
    let totalValues = data.investmentValues.values.reduce(0) { $0 + $1.count }
    progress(.importing(step: "investment values", current: 0, total: totalValues))
    var investmentValueCount = 0
    for (accountId, values) in data.investmentValues {
      for value in values {
        let record = InvestmentValueRecord(
          id: UUID(),
          profileId: profileId,
          accountId: accountId,
          date: value.date,
          value: value.value.cents,
          currencyCode: currencyCode
        )
        modelContext.insert(record)
        investmentValueCount += 1
        if investmentValueCount % 100 == 0 {
          progress(
            .importing(
              step: "investment values", current: investmentValueCount, total: totalValues)
          )
        }
      }
    }

    // 7. Save all at once (atomic)
    progress(.importing(step: "saving", current: 0, total: 1))
    logger.info(
      "Saving \(data.accounts.count) accounts, \(data.categories.count) categories, \(data.transactions.count) transactions to SwiftData"
    )
    try modelContext.save()
    logger.info("SwiftData save completed successfully")

    // Verify data persisted
    let profileId = self.profileId
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    let savedCount = (try? modelContext.fetchCount(descriptor)) ?? -1
    logger.info("Post-save verification: \(savedCount) accounts in context")

    let result = ImportResult(
      accountCount: data.accounts.count,
      categoryCount: data.categories.count,
      earmarkCount: data.earmarks.count,
      budgetItemCount: budgetItemCount,
      transactionCount: data.transactions.count,
      investmentValueCount: investmentValueCount
    )
    progress(.importComplete(result))
    return result
  }
}
