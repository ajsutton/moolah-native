import Foundation
import SwiftData

struct VerificationResult: Sendable {
  let countMatch: Bool
  let expectedCounts: EntityCounts
  let actualCounts: EntityCounts
  let balanceMismatches: [BalanceMismatch]

  struct EntityCounts: Sendable {
    let accounts: Int
    let categories: Int
    let earmarks: Int
    let transactions: Int
    let investmentValues: Int
  }

  struct BalanceMismatch: Sendable {
    let accountName: String
    let serverBalance: Int
    let localBalance: Int
  }
}

/// Verifies that imported data matches the exported data.
struct MigrationVerifier {

  func verify(
    exported: ExportedData,
    modelContainer: ModelContainer,
    profileId: UUID
  ) async throws -> VerificationResult {
    let context = ModelContext(modelContainer)

    // 1. Record counts (scoped to the new profile's profileId)
    let accountDescriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    let categoryDescriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    let earmarkDescriptor = FetchDescriptor<EarmarkRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    let txnDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )
    let investmentDescriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )

    let accountCount = try context.fetchCount(accountDescriptor)
    let categoryCount = try context.fetchCount(categoryDescriptor)
    let earmarkCount = try context.fetchCount(earmarkDescriptor)
    let txnCount = try context.fetchCount(txnDescriptor)
    let investmentValueCount = try context.fetchCount(investmentDescriptor)

    let expectedInvestmentValueCount = exported.investmentValues.values.reduce(0) { $0 + $1.count }

    let countMatch =
      accountCount == exported.accounts.count
      && categoryCount == exported.categories.count
      && earmarkCount == exported.earmarks.count
      && txnCount == exported.transactions.count
      && investmentValueCount == expectedInvestmentValueCount

    // 2. Account balance verification
    var balanceMismatches: [VerificationResult.BalanceMismatch] = []
    let allTxns = try context.fetch(txnDescriptor)

    for account in exported.accounts {
      let localBalance =
        allTxns
        .filter { $0.recurPeriod == nil }
        .reduce(0) { sum, txn in
          var delta = 0
          if txn.accountId == account.id { delta += txn.amount }
          if txn.toAccountId == account.id { delta -= txn.amount }
          return sum + delta
        }

      if localBalance != account.balance.cents {
        balanceMismatches.append(
          VerificationResult.BalanceMismatch(
            accountName: account.name,
            serverBalance: account.balance.cents,
            localBalance: localBalance
          )
        )
      }
    }

    let expectedCounts = VerificationResult.EntityCounts(
      accounts: exported.accounts.count,
      categories: exported.categories.count,
      earmarks: exported.earmarks.count,
      transactions: exported.transactions.count,
      investmentValues: expectedInvestmentValueCount
    )

    let actualCounts = VerificationResult.EntityCounts(
      accounts: accountCount,
      categories: categoryCount,
      earmarks: earmarkCount,
      transactions: txnCount,
      investmentValues: investmentValueCount
    )

    return VerificationResult(
      countMatch: countMatch && balanceMismatches.isEmpty,
      expectedCounts: expectedCounts,
      actualCounts: actualCounts,
      balanceMismatches: balanceMismatches
    )
  }
}
