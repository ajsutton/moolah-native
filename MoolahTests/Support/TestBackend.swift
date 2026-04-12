import Foundation
import SwiftData

@testable import Moolah

/// Factory for creating CloudKitBackend instances backed by an in-memory ModelContainer.
/// Used in all tests as a replacement for InMemoryBackend and individual InMemory*Repository types.
enum TestBackend {
  /// Creates a CloudKitBackend backed by an in-memory ModelContainer.
  /// Each call creates a fresh, isolated container — no cross-test contamination.
  static func create(
    currency: Currency = .defaultTestCurrency
  ) throws -> (backend: CloudKitBackend, container: ModelContainer) {
    let container = try TestModelContainer.create()
    let backend = CloudKitBackend(
      modelContainer: container,
      currency: currency,
      profileLabel: "Test"
    )
    return (backend, container)
  }

  // MARK: - Data Seeding

  /// Seeds accounts into the in-memory store.
  /// Also creates opening balance transactions for accounts with non-zero balances,
  /// matching the pattern used by CloudKit contract tests.
  @discardableResult
  static func seed(
    accounts: [Account],
    in container: ModelContainer,
    currency: Currency = .defaultTestCurrency
  ) -> [Account] {
    let context = ModelContext(container)
    for account in accounts {
      context.insert(AccountRecord.from(account, currencyCode: currency.code))
      if account.balance.cents != 0 {
        let txn = TransactionRecord(
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
  @discardableResult
  static func seed(
    transactions: [Transaction],
    in container: ModelContainer
  ) -> [Transaction] {
    let context = ModelContext(container)
    for txn in transactions {
      context.insert(TransactionRecord.from(txn))
    }
    try! context.save()
    return transactions
  }

  /// Seeds earmarks into the in-memory store.
  /// Note: Earmark saved/spent/balance are computed from transactions in CloudKitBackend,
  /// so you must also seed corresponding transactions for earmarks that need non-zero balances.
  @discardableResult
  static func seed(
    earmarks: [Earmark],
    in container: ModelContainer,
    currency: Currency = .defaultTestCurrency
  ) -> [Earmark] {
    let context = ModelContext(container)
    for earmark in earmarks {
      context.insert(
        EarmarkRecord.from(earmark, currencyCode: currency.code))
    }
    try! context.save()
    return earmarks
  }

  /// Seeds earmarks along with transactions that produce the desired saved/spent/balance values.
  /// This is the preferred way to seed earmarks with specific financial state.
  @discardableResult
  static func seedWithTransactions(
    earmarks: [Earmark],
    accountId: UUID,
    in container: ModelContainer,
    currency: Currency = .defaultTestCurrency
  ) -> [Earmark] {
    let context = ModelContext(container)
    for earmark in earmarks {
      context.insert(
        EarmarkRecord.from(earmark, currencyCode: currency.code))

      // Determine what transactions to create.
      // If saved/spent are explicitly set, use those.
      // If only balance is set (saved=0, spent=0), treat balance as the saved amount.
      let savedCents =
        earmark.saved.cents > 0
        ? earmark.saved.cents
        : (earmark.spent.cents == 0 && earmark.balance.cents > 0 ? earmark.balance.cents : 0)
      let spentCents = earmark.spent.cents

      // Create income transaction for saved amount
      if savedCents > 0 {
        let txn = TransactionRecord(
          type: TransactionType.income.rawValue,
          date: Date(),
          accountId: accountId,
          amount: savedCents,
          currencyCode: currency.code,
          earmarkId: earmark.id
        )
        context.insert(txn)
      }

      // Create expense transaction for spent amount
      if spentCents > 0 {
        let txn = TransactionRecord(
          type: TransactionType.expense.rawValue,
          date: Date(),
          accountId: accountId,
          amount: -spentCents,
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
  @discardableResult
  static func seed(
    categories: [Moolah.Category],
    in container: ModelContainer
  ) -> [Moolah.Category] {
    let context = ModelContext(container)
    for category in categories {
      context.insert(CategoryRecord.from(category))
    }
    try! context.save()
    return categories
  }

  /// Seeds investment values into the in-memory store.
  @discardableResult
  static func seed(
    investmentValues: [UUID: [InvestmentValue]],
    in container: ModelContainer,
    currency: Currency = .defaultTestCurrency
  ) -> [UUID: [InvestmentValue]] {
    let context = ModelContext(container)
    for (accountId, values) in investmentValues {
      for value in values {
        let record = InvestmentValueRecord(
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
  static func seedBudget(
    earmarkId: UUID,
    items: [EarmarkBudgetItem],
    in container: ModelContainer,
    currency: Currency = .defaultTestCurrency
  ) {
    let context = ModelContext(container)
    for item in items {
      let record = EarmarkBudgetItemRecord(
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
