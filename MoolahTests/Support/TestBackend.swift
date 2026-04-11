import Foundation
import SwiftData

@testable import Moolah

/// Factory for creating CloudKitBackend instances backed by an in-memory ModelContainer.
/// Used in all tests as a replacement for InMemoryBackend and individual InMemory*Repository types.
enum TestBackend {
  /// Creates a CloudKitBackend backed by an in-memory ModelContainer.
  /// Each call creates a fresh, isolated container — no cross-test contamination.
  static func create(
    currency: Currency = .defaultTestCurrency,
    profileId: UUID = UUID()
  ) throws -> (backend: CloudKitBackend, container: ModelContainer, profileId: UUID) {
    let container = try TestModelContainer.create()
    let backend = CloudKitBackend(
      modelContainer: container,
      profileId: profileId,
      currency: currency,
      profileLabel: "Test"
    )
    return (backend, container, profileId)
  }

  // MARK: - Data Seeding

  /// Seeds accounts into the in-memory store.
  /// Also creates opening balance transactions for accounts with non-zero balances,
  /// matching the pattern used by CloudKit contract tests.
  @MainActor @discardableResult
  static func seed(
    accounts: [Account],
    in container: ModelContainer,
    profileId: UUID,
    currency: Currency = .defaultTestCurrency
  ) -> [Account] {
    let context = container.mainContext
    for account in accounts {
      context.insert(AccountRecord.from(account, profileId: profileId, currencyCode: currency.code))
      if account.balance.cents != 0 {
        let txn = TransactionRecord(
          profileId: profileId,
          type: TransactionType.openingBalance.rawValue,
          date: Date(),
          accountId: account.id,
          amount: account.balance.cents,
          currencyCode: currency.code
        )
        context.insert(txn)
      }
    }
    try! context.save()
    return accounts
  }

  /// Seeds transactions into the in-memory store.
  @MainActor @discardableResult
  static func seed(
    transactions: [Transaction],
    in container: ModelContainer,
    profileId: UUID
  ) -> [Transaction] {
    let context = container.mainContext
    for txn in transactions {
      context.insert(TransactionRecord.from(txn, profileId: profileId))
    }
    try! context.save()
    return transactions
  }

  /// Seeds earmarks into the in-memory store.
  /// Note: Earmark saved/spent/balance are computed from transactions in CloudKitBackend,
  /// so you must also seed corresponding transactions for earmarks that need non-zero balances.
  @MainActor @discardableResult
  static func seed(
    earmarks: [Earmark],
    in container: ModelContainer,
    profileId: UUID,
    currency: Currency = .defaultTestCurrency
  ) -> [Earmark] {
    let context = container.mainContext
    for earmark in earmarks {
      context.insert(
        EarmarkRecord.from(earmark, profileId: profileId, currencyCode: currency.code))
    }
    try! context.save()
    return earmarks
  }

  /// Seeds earmarks along with transactions that produce the desired saved/spent/balance values.
  /// This is the preferred way to seed earmarks with specific financial state.
  @MainActor @discardableResult
  static func seedWithTransactions(
    earmarks: [Earmark],
    accountId: UUID,
    in container: ModelContainer,
    profileId: UUID,
    currency: Currency = .defaultTestCurrency
  ) -> [Earmark] {
    let context = container.mainContext
    for earmark in earmarks {
      context.insert(
        EarmarkRecord.from(earmark, profileId: profileId, currencyCode: currency.code))

      // Create income transactions for saved amount
      if earmark.saved.cents > 0 {
        let txn = TransactionRecord(
          profileId: profileId,
          type: TransactionType.income.rawValue,
          date: Date(),
          accountId: accountId,
          amount: earmark.saved.cents,
          currencyCode: currency.code,
          earmarkId: earmark.id
        )
        context.insert(txn)
      }

      // Create expense transactions for spent amount
      if earmark.spent.cents > 0 {
        let txn = TransactionRecord(
          profileId: profileId,
          type: TransactionType.expense.rawValue,
          date: Date(),
          accountId: accountId,
          amount: -earmark.spent.cents,
          currencyCode: currency.code,
          earmarkId: earmark.id
        )
        context.insert(txn)
      }
    }
    try! context.save()
    return earmarks
  }

  /// Seeds categories into the in-memory store.
  @MainActor @discardableResult
  static func seed(
    categories: [Moolah.Category],
    in container: ModelContainer,
    profileId: UUID
  ) -> [Moolah.Category] {
    let context = container.mainContext
    for category in categories {
      context.insert(CategoryRecord.from(category, profileId: profileId))
    }
    try! context.save()
    return categories
  }

  /// Seeds investment values into the in-memory store.
  @MainActor @discardableResult
  static func seed(
    investmentValues: [UUID: [InvestmentValue]],
    in container: ModelContainer,
    profileId: UUID,
    currency: Currency = .defaultTestCurrency
  ) -> [UUID: [InvestmentValue]] {
    let context = container.mainContext
    for (accountId, values) in investmentValues {
      for value in values {
        let record = InvestmentValueRecord(
          profileId: profileId,
          accountId: accountId,
          date: value.date,
          value: value.value.cents,
          currencyCode: currency.code
        )
        context.insert(record)
      }
    }
    try! context.save()
    return investmentValues
  }

  /// Seeds earmark budget items into the in-memory store.
  @MainActor
  static func seedBudget(
    earmarkId: UUID,
    items: [EarmarkBudgetItem],
    in container: ModelContainer,
    profileId: UUID,
    currency: Currency = .defaultTestCurrency
  ) {
    let context = container.mainContext
    for item in items {
      let record = EarmarkBudgetItemRecord(
        profileId: profileId,
        earmarkId: earmarkId,
        categoryId: item.categoryId,
        amount: item.amount.cents,
        currencyCode: currency.code
      )
      context.insert(record)
    }
    try! context.save()
  }
}
