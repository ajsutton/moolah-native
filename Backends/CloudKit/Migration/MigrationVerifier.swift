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
    modelContainer: ModelContainer
  ) async throws -> VerificationResult {
    let context = ModelContext(modelContainer)

    // 1. Record counts (store is profile-scoped, no predicate needed)
    let accountDescriptor = FetchDescriptor<AccountRecord>()
    let categoryDescriptor = FetchDescriptor<CategoryRecord>()
    let earmarkDescriptor = FetchDescriptor<EarmarkRecord>()
    let txnDescriptor = FetchDescriptor<TransactionRecord>()
    let investmentDescriptor = FetchDescriptor<InvestmentValueRecord>()

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

    // 2. Account balance verification — computed from exported data directly
    //    (avoids ModelContext isolation issues with re-querying imported records)
    var balanceMismatches: [VerificationResult.BalanceMismatch] = []
    let nonScheduledTxns = exported.transactions.filter { !$0.isScheduled }

    for account in exported.accounts {
      let computedBalance: Decimal = nonScheduledTxns.reduce(Decimal(0)) { sum, txn in
        var delta = sum
        for leg in txn.legs where leg.accountId == account.id {
          delta += leg.quantity
        }
        return delta
      }

      if computedBalance != account.balance.quantity {
        balanceMismatches.append(
          VerificationResult.BalanceMismatch(
            accountName: account.name,
            serverBalance: Int(truncating: (account.balance.quantity * 100) as NSDecimalNumber),
            localBalance: Int(truncating: (computedBalance * 100) as NSDecimalNumber)
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
      countMatch: countMatch,
      expectedCounts: expectedCounts,
      actualCounts: actualCounts,
      balanceMismatches: balanceMismatches
    )
  }
}
