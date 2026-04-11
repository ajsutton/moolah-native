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
  private let profileId: UUID
  private let currencyCode: String
  private let logger = Logger(subsystem: "com.moolah.app", category: "Migration")

  init(modelContainer: ModelContainer, profileId: UUID, currencyCode: String) {
    self.modelContainer = modelContainer
    self.profileId = profileId
    self.currencyCode = currencyCode
  }

  @discardableResult
  func importData(_ data: ExportedData) throws -> ImportResult {
    let context = modelContainer.mainContext

    // 1. Categories (no dependencies)
    for category in data.categories {
      let record = CategoryRecord(
        id: category.id,
        profileId: profileId,
        name: category.name,
        parentId: category.parentId
      )
      context.insert(record)
    }

    // 2. Accounts (no dependencies)
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

    // 5. Transactions
    for txn in data.transactions {
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
    }

    // 6. Investment values
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
      }
    }

    // 7. Save
    logger.info(
      "Saving to SwiftData — context.hasChanges=\(context.hasChanges)"
    )

    // Check a single inserted record before save
    if let firstAccount = data.accounts.first {
      let testId = firstAccount.id
      let beforeDescriptor = FetchDescriptor<AccountRecord>(
        predicate: #Predicate { $0.id == testId }
      )
      let beforeCount = (try? context.fetchCount(beforeDescriptor)) ?? -1
      logger.info(
        "Before save: account \(firstAccount.name) (id=\(testId)) fetchCount=\(beforeCount)")
    }

    try context.save()
    logger.info("SwiftData save completed, context.hasChanges=\(context.hasChanges)")

    // Verify with and without predicate
    let allDescriptor = FetchDescriptor<AccountRecord>()
    let allCount = (try? context.fetchCount(allDescriptor)) ?? -1
    let profileId = self.profileId
    let filteredDescriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    let filteredCount = (try? context.fetchCount(filteredDescriptor)) ?? -1
    logger.info(
      "Post-save: ALL accounts=\(allCount), filtered by profileId=\(filteredCount), profileId=\(profileId)"
    )

    // Check store URL
    for config in context.container.configurations {
      logger.info("Store URL: \(config.url.absoluteString)")
    }

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
