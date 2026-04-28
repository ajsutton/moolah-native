import Foundation
import SwiftData

struct ImportEntityCounts: Sendable {
  let accounts: Int
  let categories: Int
  let earmarks: Int
  let transactions: Int
  let investmentValues: Int
}

struct ImportVerificationResult: Sendable {
  let countMatch: Bool
  let expectedCounts: ImportEntityCounts
  let actualCounts: ImportEntityCounts
}

/// Confirms that row counts in the SwiftData container match the source
/// export file after `CloudKitDataImporter` completes. A count mismatch
/// indicates a partial import (e.g. mid-flight crash or constraint violation)
/// and prevents the coordinator from activating the new profile.
struct ImportVerifier {

  func verify(
    exported: ExportedData,
    modelContainer: ModelContainer
  ) async throws -> ImportVerificationResult {
    let context = ModelContext(modelContainer)
    let actualCounts = try fetchActualCounts(context: context)

    let expectedInvestmentValueCount = exported.investmentValues.values.reduce(0) { $0 + $1.count }
    let expectedCounts = ImportEntityCounts(
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

    return ImportVerificationResult(
      countMatch: countMatch,
      expectedCounts: expectedCounts,
      actualCounts: actualCounts
    )
  }

  /// Record counts (store is profile-scoped, no predicate needed).
  private func fetchActualCounts(
    context: ModelContext
  ) throws -> ImportEntityCounts {
    ImportEntityCounts(
      accounts: try context.fetchCount(FetchDescriptor<AccountRecord>()),
      categories: try context.fetchCount(FetchDescriptor<CategoryRecord>()),
      earmarks: try context.fetchCount(FetchDescriptor<EarmarkRecord>()),
      transactions: try context.fetchCount(FetchDescriptor<TransactionRecord>()),
      investmentValues: try context.fetchCount(FetchDescriptor<InvestmentValueRecord>())
    )
  }
}
