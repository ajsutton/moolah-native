import Foundation
import SwiftData

@testable import Moolah

// MARK: - Scale

/// Defines the scale multiplier for benchmark fixture generation.
struct BenchmarkScale: Sendable {
  let transactions: Int
  let accounts: Int
  let categories: Int
  let earmarks: Int
  let investmentValues: Int
  /// Number of accounts designated as investment type (placed at the end).
  let investmentAccounts: Int

  static let x1 = BenchmarkScale(
    transactions: 18_662,
    accounts: 31,
    categories: 158,
    earmarks: 21,
    investmentValues: 2_711,
    investmentAccounts: 6
  )

  static let x2 = BenchmarkScale(
    transactions: 37_324,
    accounts: 62,
    categories: 316,
    earmarks: 42,
    investmentValues: 5_422,
    investmentAccounts: 12
  )
}

// MARK: - BenchmarkFixtures

/// Generates realistic benchmark datasets matching the live iCloud profile distribution.
///
/// Real data profile (1x):
/// - 18,662 transactions across 31 accounts (top 3 hold ~85%)
/// - 158 categories, 21 earmarks, 2,711 investment values
/// - ~0.2% scheduled transactions
enum BenchmarkFixtures {

  // MARK: - Well-Known IDs

  /// The 3 heavy accounts that hold ~85% of transactions.
  /// Transaction distribution: ~38% heavy0, ~32% heavy1, ~16% heavy2, ~14% others.
  static let heavyAccountIds: [UUID] = [
    UUID(uuidString: "00000000-BE00-0000-0000-000000000001")!,
    UUID(uuidString: "00000000-BE00-0000-0000-000000000002")!,
    UUID(uuidString: "00000000-BE00-0000-0000-000000000003")!,
  ]

  /// The single busiest account (~38% of all transactions).
  static var heavyAccountId: UUID { heavyAccountIds[0] }

  // MARK: - Seeding

  /// Seeds a complete benchmark dataset into the given container.
  ///
  /// - Parameters:
  ///   - scale: The dataset scale (`.x1` for real-data-sized, `.x2` for double).
  ///   - container: An in-memory `ModelContainer` to populate.
  @MainActor
  static func seed(scale: BenchmarkScale, in container: ModelContainer) {
    let context = container.mainContext
    let currency = Currency.defaultTestCurrency

    let accountIds = seedAccounts(scale: scale, in: context, currency: currency)
    let categoryIds = seedCategories(scale: scale, in: context)
    let earmarkIds = seedEarmarks(scale: scale, in: context, currency: currency)
    seedTransactions(
      scale: scale,
      accountIds: accountIds,
      categoryIds: categoryIds,
      earmarkIds: earmarkIds,
      in: context,
      currency: currency
    )
    seedInvestmentValues(
      scale: scale,
      accountIds: accountIds,
      in: context,
      currency: currency
    )

    try! context.save()
  }

  // MARK: - Private Helpers

  /// Deterministic UUID from a namespace and index.
  private static func deterministicUUID(namespace: UInt8, index: Int) -> UUID {
    // Build a UUID with the namespace byte in position 0 and index bytes in positions 12-15.
    let idx = UInt32(index)
    let uuidString = String(
      format: "%02X000000-BE00-4000-A000-%012X",
      namespace, idx
    )
    return UUID(uuidString: uuidString)!
  }

  @MainActor
  private static func seedAccounts(
    scale: BenchmarkScale,
    in context: ModelContext,
    currency: Currency
  ) -> [UUID] {
    var ids: [UUID] = []

    // First 3 are the heavy accounts with well-known IDs.
    for i in 0..<min(3, scale.accounts) {
      let id = heavyAccountIds[i]
      ids.append(id)
      let record = AccountRecord(
        id: id,
        name: "Heavy Account \(i)",
        type: AccountType.bank.rawValue,
        position: i,
        currencyCode: currency.code
      )
      context.insert(record)
    }

    // Remaining non-investment accounts.
    let nonInvestmentRemaining = scale.accounts - 3 - scale.investmentAccounts
    for i in 0..<nonInvestmentRemaining {
      let id = deterministicUUID(namespace: 0x01, index: i)
      ids.append(id)
      // Alternate between bank, credit card, and asset.
      let accountType: AccountType =
        switch i % 3 {
        case 0: .bank
        case 1: .creditCard
        default: .asset
        }
      let record = AccountRecord(
        id: id,
        name: "Account \(i + 3)",
        type: accountType.rawValue,
        position: i + 3,
        currencyCode: currency.code
      )
      context.insert(record)
    }

    // Investment accounts (last N).
    for i in 0..<scale.investmentAccounts {
      let id = deterministicUUID(namespace: 0x02, index: i)
      ids.append(id)
      let record = AccountRecord(
        id: id,
        name: "Investment \(i)",
        type: AccountType.investment.rawValue,
        position: scale.accounts - scale.investmentAccounts + i,
        currencyCode: currency.code
      )
      context.insert(record)
    }

    return ids
  }

  @MainActor
  private static func seedCategories(
    scale: BenchmarkScale,
    in context: ModelContext
  ) -> [UUID] {
    var ids: [UUID] = []
    for i in 0..<scale.categories {
      let id = deterministicUUID(namespace: 0x03, index: i)
      ids.append(id)
      // ~20% are child categories (have a parent).
      let parentId: UUID? =
        (i >= 10 && i % 5 == 0)
        ? ids[i / 5]
        : nil
      let record = CategoryRecord(
        id: id,
        name: "Category \(i)",
        parentId: parentId
      )
      context.insert(record)
    }
    return ids
  }

  @MainActor
  private static func seedEarmarks(
    scale: BenchmarkScale,
    in context: ModelContext,
    currency: Currency
  ) -> [UUID] {
    var ids: [UUID] = []
    for i in 0..<scale.earmarks {
      let id = deterministicUUID(namespace: 0x04, index: i)
      ids.append(id)
      // Half have savings targets.
      let savingsTarget: Int? = i % 2 == 0 ? (i + 1) * 100_00 : nil
      let record = EarmarkRecord(
        id: id,
        name: "Earmark \(i)",
        position: i,
        savingsTarget: savingsTarget,
        currencyCode: currency.code
      )
      context.insert(record)
    }
    return ids
  }

  @MainActor
  private static func seedTransactions(
    scale: BenchmarkScale,
    accountIds: [UUID],
    categoryIds: [UUID],
    earmarkIds: [UUID],
    in context: ModelContext,
    currency: Currency
  ) {
    let fiveYearsAgo = Calendar.current.date(byAdding: .year, value: -5, to: Date())!
    let timeSpan = Date().timeIntervalSince(fiveYearsAgo)
    let scheduledCount = max(1, Int(Double(scale.transactions) * 0.002))
    // Non-heavy account IDs for the remaining ~14%.
    let otherAccountIds = Array(accountIds.dropFirst(3))

    for i in 0..<scale.transactions {
      let id = deterministicUUID(namespace: 0x05, index: i)

      // Distribute across accounts: 38% heavy0, 32% heavy1, 16% heavy2, 14% others.
      let accountId: UUID
      let bucket = i % 100
      if bucket < 38 {
        accountId = heavyAccountIds[0]
      } else if bucket < 70 {
        accountId = heavyAccountIds[1]
      } else if bucket < 86 {
        accountId = heavyAccountIds[2]
      } else if !otherAccountIds.isEmpty {
        accountId = otherAccountIds[i % otherAccountIds.count]
      } else {
        accountId = heavyAccountIds[0]
      }

      // Transaction type: 60% expense, 30% income, 10% transfer.
      let typeBucket = i % 10
      let txnType: TransactionType
      var toAccountId: UUID?
      if typeBucket < 6 {
        txnType = .expense
      } else if typeBucket < 9 {
        txnType = .income
      } else {
        txnType = .transfer
        // Pick a different account for the destination.
        let destIndex = (accountIds.firstIndex(of: accountId) ?? 0 + 1) % accountIds.count
        toAccountId = accountIds[destIndex]
      }

      // Spread dates across 5 years deterministically.
      let fraction = Double(i) / Double(max(1, scale.transactions - 1))
      let date = fiveYearsAgo.addingTimeInterval(fraction * timeSpan)

      // Amount: vary between -500_00 and 500_00 cents.
      let amount: Int
      switch txnType {
      case .expense:
        amount = -((i % 500 + 1) * 100)
      case .income:
        amount = (i % 800 + 1) * 100
      case .transfer:
        amount = (i % 300 + 1) * 100
      default:
        amount = 0
      }

      // Assign category to ~70% of transactions.
      let categoryId: UUID? =
        (i % 10 < 7 && !categoryIds.isEmpty)
        ? categoryIds[i % categoryIds.count]
        : nil

      // Assign earmark to ~5% of transactions.
      let earmarkId: UUID? =
        (i % 20 == 0 && !earmarkIds.isEmpty)
        ? earmarkIds[i % earmarkIds.count]
        : nil

      // ~0.2% are scheduled (recurring).
      let isScheduled = i < scheduledCount
      let recurPeriod: String? = isScheduled ? RecurPeriod.month.rawValue : nil
      let recurEvery: Int? = isScheduled ? 1 : nil

      let record = TransactionRecord(
        id: id,
        type: txnType.rawValue,
        date: date,
        accountId: accountId,
        toAccountId: toAccountId,
        amount: amount,
        currencyCode: currency.code,
        payee: "Payee \(i % 200)",
        categoryId: categoryId,
        earmarkId: earmarkId,
        recurPeriod: recurPeriod,
        recurEvery: recurEvery
      )
      context.insert(record)
    }
  }

  @MainActor
  private static func seedInvestmentValues(
    scale: BenchmarkScale,
    accountIds: [UUID],
    in context: ModelContext,
    currency: Currency
  ) {
    // Investment accounts are the last N in the account list.
    let investmentAccountIds = Array(accountIds.suffix(scale.investmentAccounts))
    guard !investmentAccountIds.isEmpty else { return }

    let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: Date())!
    let timeSpan = Date().timeIntervalSince(sixMonthsAgo)

    for i in 0..<scale.investmentValues {
      let id = deterministicUUID(namespace: 0x06, index: i)
      let investAccountId = investmentAccountIds[i % investmentAccountIds.count]

      let fraction = Double(i) / Double(max(1, scale.investmentValues - 1))
      let date = sixMonthsAgo.addingTimeInterval(fraction * timeSpan)

      // Value between 10,000 and 500,000 cents.
      let value = (i % 4900 + 100) * 100

      let record = InvestmentValueRecord(
        id: id,
        accountId: investAccountId,
        date: date,
        value: value,
        currencyCode: currency.code
      )
      context.insert(record)
    }
  }
}
