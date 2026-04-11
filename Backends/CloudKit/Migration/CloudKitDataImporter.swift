import Foundation
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
actor CloudKitDataImporter {
  private let modelContainer: ModelContainer
  private let profileId: UUID
  private let currencyCode: String

  enum ImportProgress: Sendable {
    case importing(step: String, current: Int, total: Int)
    case importComplete(ImportResult)
    case failed(Error)
  }

  init(modelContainer: ModelContainer, profileId: UUID, currencyCode: String) {
    self.modelContainer = modelContainer
    self.profileId = profileId
    self.currencyCode = currencyCode
  }

  func importData(
    _ data: ExportedData,
    progress: @escaping @Sendable (ImportProgress) -> Void
  ) async throws -> ImportResult {
    let context = ModelContext(modelContainer)

    do {
      // 1. Categories (no dependencies)
      progress(.importing(step: "categories", current: 0, total: data.categories.count))
      for (i, category) in data.categories.enumerated() {
        let record = CategoryRecord(
          id: category.id,
          profileId: profileId,
          name: category.name,
          parentId: category.parentId
        )
        context.insert(record)
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
        context.insert(record)
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
        context.insert(record)
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
          context.insert(record)
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
        context.insert(record)

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
          context.insert(record)
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
      try context.save()

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
    } catch {
      throw MigrationError.importFailed(underlying: error)
    }
  }
}
