import Foundation
import SwiftData

@testable import Moolah

/// Factory for creating CloudKitBackend instances backed by an in-memory ModelContainer.
/// Used in all tests as a replacement for InMemoryBackend and individual InMemory*Repository types.
enum TestBackend {
  /// Creates a CloudKitBackend backed by an in-memory ModelContainer.
  /// Each call creates a fresh, isolated container — no cross-test contamination.
  static func create(
    instrument: Instrument = .defaultTestInstrument
  ) throws -> (backend: CloudKitBackend, container: ModelContainer) {
    let container = try TestModelContainer.create()
    let backend = CloudKitBackend(
      modelContainer: container,
      instrument: instrument,
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
    instrument: Instrument = .defaultTestInstrument
  ) -> [Account] {
    let context = ModelContext(container)
    for account in accounts {
      context.insert(AccountRecord.from(account))
      if !account.balance.isZero {
        let txnId = UUID()
        let txn = TransactionRecord(
          id: txnId,
          date: Date(),
          recurPeriod: nil,
          recurEvery: nil
        )
        context.insert(txn)
        let leg = TransactionLegRecord(
          transactionId: txnId,
          accountId: account.id,
          instrumentId: instrument.id,
          quantity: account.balance.storageValue,
          type: TransactionType.openingBalance.rawValue,
          sortOrder: 0
        )
        context.insert(leg)
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
      for (index, leg) in txn.legs.enumerated() {
        context.insert(TransactionLegRecord.from(leg, transactionId: txn.id, sortOrder: index))
      }
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
    instrument: Instrument = .defaultTestInstrument
  ) -> [Earmark] {
    let context = ModelContext(container)
    for earmark in earmarks {
      context.insert(
        EarmarkRecord.from(earmark))
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
    instrument: Instrument = .defaultTestInstrument
  ) -> [Earmark] {
    let context = ModelContext(container)
    for earmark in earmarks {
      context.insert(
        EarmarkRecord.from(earmark))

      // Determine what transactions to create.
      // If saved/spent are explicitly set, use those.
      // If only balance is set (saved=0, spent=0), treat balance as the saved amount.
      let savedAmount =
        !earmark.saved.isZero
        ? earmark.saved
        : (earmark.spent.isZero && !earmark.balance.isZero
          ? earmark.balance : .zero(instrument: instrument))
      let spentAmount = earmark.spent

      // Create income transaction for saved amount
      if !savedAmount.isZero {
        let txnId = UUID()
        let txn = TransactionRecord(
          id: txnId,
          date: Date()
        )
        context.insert(txn)
        let leg = TransactionLegRecord(
          transactionId: txnId,
          accountId: accountId,
          instrumentId: instrument.id,
          quantity: savedAmount.storageValue,
          type: TransactionType.income.rawValue,
          earmarkId: earmark.id,
          sortOrder: 0
        )
        context.insert(leg)
      }

      // Create expense transaction for spent amount
      if !spentAmount.isZero {
        let txnId = UUID()
        let txn = TransactionRecord(
          id: txnId,
          date: Date()
        )
        context.insert(txn)
        let leg = TransactionLegRecord(
          transactionId: txnId,
          accountId: accountId,
          instrumentId: instrument.id,
          quantity: (-spentAmount).storageValue,
          type: TransactionType.expense.rawValue,
          earmarkId: earmark.id,
          sortOrder: 0
        )
        context.insert(leg)
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
    instrument: Instrument = .defaultTestInstrument
  ) -> [UUID: [InvestmentValue]] {
    let context = ModelContext(container)
    for (accountId, values) in investmentValues {
      for value in values {
        let record = InvestmentValueRecord(
          accountId: accountId,
          date: value.date,
          value: value.value.storageValue,
          instrumentId: instrument.id
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
    instrument: Instrument = .defaultTestInstrument
  ) {
    let context = ModelContext(container)
    for item in items {
      let record = EarmarkBudgetItemRecord(
        earmarkId: earmarkId,
        categoryId: item.categoryId,
        amount: item.amount.storageValue,
        instrumentId: instrument.id
      )
      context.insert(record)
    }
    try! context.save()
  }
}
