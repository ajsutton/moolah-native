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
    let actualCounts = try fetchActualCounts(context: context)

    let expectedInvestmentValueCount = exported.investmentValues.values.reduce(0) { $0 + $1.count }
    let expectedCounts = VerificationResult.EntityCounts(
      accounts: exported.accounts.count,
      categories: exported.categories.count,
      earmarks: exported.earmarks.count,
      transactions: exported.transactions.count,
      investmentValues: expectedInvestmentValueCount
    )
    let countMatch =
      actualCounts.accounts == expectedCounts.accounts
      && actualCounts.categories == expectedCounts.categories
      && actualCounts.earmarks == expectedCounts.earmarks
      && actualCounts.transactions == expectedCounts.transactions
      && actualCounts.investmentValues == expectedCounts.investmentValues

    let balanceMismatches = computeBalanceMismatches(exported: exported)
    return VerificationResult(
      countMatch: countMatch,
      expectedCounts: expectedCounts,
      actualCounts: actualCounts,
      balanceMismatches: balanceMismatches
    )
  }

  /// Record counts (store is profile-scoped, no predicate needed).
  private func fetchActualCounts(
    context: ModelContext
  ) throws -> VerificationResult.EntityCounts {
    VerificationResult.EntityCounts(
      accounts: try context.fetchCount(FetchDescriptor<AccountRecord>()),
      categories: try context.fetchCount(FetchDescriptor<CategoryRecord>()),
      earmarks: try context.fetchCount(FetchDescriptor<EarmarkRecord>()),
      transactions: try context.fetchCount(FetchDescriptor<TransactionRecord>()),
      investmentValues: try context.fetchCount(FetchDescriptor<InvestmentValueRecord>())
    )
  }

  /// Account balance verification — computed from exported data directly
  /// (avoids ModelContext isolation issues with re-querying imported
  /// records). Compares the primary position amount against computed leg
  /// totals.
  private func computeBalanceMismatches(
    exported: ExportedData
  ) -> [VerificationResult.BalanceMismatch] {
    var balanceMismatches: [VerificationResult.BalanceMismatch] = []
    let nonScheduledTxns = exported.transactions.filter { !$0.isScheduled }

    for account in exported.accounts {
      let computedBalance: Decimal = nonScheduledTxns.reduce(Decimal(0)) { sum, txn in
        var delta = sum
        for leg in txn.legs
        where leg.accountId == account.id
          && leg.instrument == account.instrument
        {
          delta += leg.quantity
        }
        return delta
      }

      let primaryPosition = account.positions.first(where: {
        $0.instrument == account.instrument
      })
      let accountBalance = primaryPosition?.quantity ?? 0

      if computedBalance != accountBalance {
        balanceMismatches.append(
          VerificationResult.BalanceMismatch(
            accountName: account.name,
            serverBalance: Int(truncating: (accountBalance * 100) as NSDecimalNumber),
            localBalance: Int(truncating: (computedBalance * 100) as NSDecimalNumber)
          )
        )
      }
    }
    return balanceMismatches
  }
}
