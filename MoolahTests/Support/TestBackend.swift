import Foundation
import SwiftData

@testable import Moolah

/// Factory for creating CloudKitBackend instances backed by an in-memory ModelContainer.
/// Used in all tests as a replacement for InMemoryBackend and individual InMemory*Repository types.
enum TestBackend {
  /// Creates a CloudKitBackend backed by an in-memory ModelContainer.
  /// Each call creates a fresh, isolated container — no cross-test contamination.
  static func create(
    instrument: Instrument = .defaultTestInstrument,
    exchangeRates: [String: [String: Decimal]] = [:]
  ) throws -> (backend: CloudKitBackend, container: ModelContainer) {
    let container = try TestModelContainer.create()
    let rateClient = FixedRateClient(rates: exchangeRates)
    let cacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("test-rates-\(UUID().uuidString)")
    let exchangeRateService = ExchangeRateService(client: rateClient, cacheDirectory: cacheDir)
    let conversionService = FiatConversionService(exchangeRates: exchangeRateService)
    let backend = CloudKitBackend(
      modelContainer: container,
      instrument: instrument,
      profileLabel: "Test",
      conversionService: conversionService
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
  /// Also creates InstrumentRecord entries for non-fiat instruments so they resolve correctly on fetch.
  @discardableResult
  static func seed(
    transactions: [Transaction],
    in container: ModelContainer
  ) -> [Transaction] {
    let context = ModelContext(container)
    var seenInstruments: Set<String> = []
    for txn in transactions {
      context.insert(TransactionRecord.from(txn))
      for (index, leg) in txn.legs.enumerated() {
        // Ensure non-fiat instruments have InstrumentRecord entries
        if leg.instrument.kind != .fiatCurrency && !seenInstruments.contains(leg.instrument.id) {
          seenInstruments.insert(leg.instrument.id)
          context.insert(InstrumentRecord.from(leg.instrument))
        }
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

  /// Seeds earmarks along with transactions that produce the desired saved/spent values.
  /// `amounts` maps earmark ID to (saved, spent) quantities as Decimals.
  /// If an earmark has no entry in amounts, no transactions are created.
  @discardableResult
  static func seedWithTransactions(
    earmarks: [Earmark],
    amounts: [UUID: (saved: Decimal, spent: Decimal)] = [:],
    accountId: UUID,
    in container: ModelContainer,
    instrument: Instrument = .defaultTestInstrument
  ) -> [Earmark] {
    let context = ModelContext(container)
    for earmark in earmarks {
      context.insert(EarmarkRecord.from(earmark))

      let earmarkAmounts = amounts[earmark.id]
      let savedQty = earmarkAmounts?.saved ?? 0
      let spentQty = earmarkAmounts?.spent ?? 0

      if savedQty != 0 {
        let txnId = UUID()
        let txn = TransactionRecord(id: txnId, date: Date())
        context.insert(txn)
        let leg = TransactionLegRecord(
          transactionId: txnId,
          accountId: accountId,
          instrumentId: instrument.id,
          quantity: InstrumentAmount(quantity: savedQty, instrument: instrument).storageValue,
          type: TransactionType.income.rawValue,
          earmarkId: earmark.id,
          sortOrder: 0
        )
        context.insert(leg)
      }

      if spentQty != 0 {
        let txnId = UUID()
        let txn = TransactionRecord(id: txnId, date: Date())
        context.insert(txn)
        let leg = TransactionLegRecord(
          transactionId: txnId,
          accountId: accountId,
          instrumentId: instrument.id,
          quantity: InstrumentAmount(quantity: -spentQty, instrument: instrument).storageValue,
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
